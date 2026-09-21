# name: discourse-added-to-group-notifier
# about: Sends a PM (from the system user) to configured recipients when a user is added to one of a configured list of groups. Supports up to 5 independent notifiers, each with its own watched groups, recipients, and message templates. Polls the DB on a schedule rather than relying on Discourse's user_added_to_group event, so it works reliably even when membership changes come from bulk/dynamic-group syncs that bypass that event.
# version: 0.5
# authors: jronielky

require_relative "lib/discourse_added_to_group_notifier/engine"
enabled_site_setting :added_to_group_notifier_enabled

module ::AddedToGroupNotifier
  PLUGIN_NAME = "discourse-added-to-group-notifier"

  LAST_CHECKED_AT_KEY = "last_checked_at"
  PROCESSED_PREFIX = "processed_group_user_"

  LOCK_NAME = "discourse-added-to-group-notifier-check"
  LOCK_VALIDITY = 10.minutes

  POLLING_LOOKBACK = 10.minutes
  BATCH_SIZE = 100

  TEMPLATE_VARIABLES = %i[username group_name added_at].freeze

  # Slot 1 reuses the plugin's original (unsuffixed) setting names, so
  # existing single-notifier installs keep working with zero reconfiguration.
  # Slots 2-5 are optional, additional notifiers using suffixed setting
  # names; leaving a slot's "groups" setting blank disables that slot.
  NOTIFIER_SLOTS = (1..5).freeze

  module_function

  # Maps a notifier slot + setting key (:groups, :recipient_usernames,
  # :recipient_groups, :pm_title, :pm_body) to the underlying site setting
  # name.
  def setting_name(slot, key)
    if slot == 1
      :"added_to_group_notifier_#{key}"
    else
      :"added_to_group_notifier_#{slot}_#{key}"
    end
  end

  # Returns the numeric IDs configured in a Discourse group_list setting.
  #
  # Modern Discourse versions expose group_list settings through a _map
  # accessor that returns an array of group IDs. The fallback supports older
  # versions that expose the raw pipe-separated setting value.
  def configured_group_ids(setting_name)
    map_method = "#{setting_name}_map"

    values =
      if SiteSetting.respond_to?(map_method)
        SiteSetting.public_send(map_method)
      else
        SiteSetting
          .public_send(setting_name)
          .to_s
          .split("|")
      end

    Array(values)
      .flatten
      .map(&:to_i)
      .reject(&:zero?)
      .uniq
  rescue StandardError => e
    Rails.logger.error(
      "[#{PLUGIN_NAME}] Could not read group setting #{setting_name}: " \
      "#{e.class}: #{e.message}"
    )

    []
  end

  def configured_recipient_usernames(setting_name)
    configured_names =
      SiteSetting
        .public_send(setting_name)
        .to_s
        .split("|")
        .map(&:strip)
        .reject(&:blank?)
        .uniq

    return [] if configured_names.blank?

    users_by_username =
      User
        .where(username_lower: configured_names.map(&:downcase))
        .pluck(:username)
        .index_by(&:downcase)

    resolved_names = configured_names.filter_map do |username|
      users_by_username[username.downcase]
    end

    missing_names =
      configured_names.reject do |username|
        users_by_username.key?(username.downcase)
      end

    if missing_names.present?
      Rails.logger.warn(
        "[#{PLUGIN_NAME}] Ignoring unknown recipient usernames " \
        "(#{setting_name}): #{missing_names.join(", ")}"
      )
    end

    resolved_names.uniq
  rescue StandardError => e
    Rails.logger.error(
      "[#{PLUGIN_NAME}] Could not resolve recipient usernames " \
      "(#{setting_name}): #{e.class}: #{e.message}"
    )

    []
  end

  def configured_recipient_group_names(setting_name)
    group_ids = configured_group_ids(setting_name)

    return [] if group_ids.blank?

    existing_groups =
      Group
        .where(id: group_ids)
        .pluck(:id, :name)
        .to_h

    missing_ids = group_ids - existing_groups.keys

    if missing_ids.present?
      Rails.logger.warn(
        "[#{PLUGIN_NAME}] Ignoring nonexistent recipient group IDs " \
        "(#{setting_name}): #{missing_ids.join(", ")}"
      )
    end

    group_ids.filter_map { |group_id| existing_groups[group_id] }.uniq
  rescue StandardError => e
    Rails.logger.error(
      "[#{PLUGIN_NAME}] Could not resolve recipient groups " \
      "(#{setting_name}): #{e.class}: #{e.message}"
    )

    []
  end

  def render_template(template, variables)
    template.to_s.gsub(/%\{(\w+)\}/) do
      variable_name = Regexp.last_match(1).to_sym

      if TEMPLATE_VARIABLES.include?(variable_name)
        variables.fetch(variable_name, "").to_s
      else
        Rails.logger.warn(
          "[#{PLUGIN_NAME}] Unknown template variable: #{variable_name}"
        )

        "%{#{variable_name}}"
      end
    end
  end

  def read_last_checked_at
    stored_value = PluginStore.get(PLUGIN_NAME, LAST_CHECKED_AT_KEY)

    return POLLING_LOOKBACK.ago if stored_value.blank?

    parsed_time = Time.zone.parse(stored_value.to_s)

    return parsed_time if parsed_time.present?

    raise ArgumentError, "stored timestamp could not be parsed"
  rescue ArgumentError, TypeError => e
    Rails.logger.warn(
      "[#{PLUGIN_NAME}] Invalid stored polling timestamp " \
      "#{stored_value.inspect}: #{e.message}. Using lookback window."
    )

    POLLING_LOOKBACK.ago
  end

  def write_last_checked_at(timestamp)
    PluginStore.set(
      PLUGIN_NAME,
      LAST_CHECKED_AT_KEY,
      timestamp.in_time_zone.iso8601(6)
    )
  end

  # Slot 1 keeps the original, unsuffixed processed-marker key so upgrading
  # from a single-notifier install doesn't re-notify recently processed
  # rows. Slots 2-5 get their own independent marker per group_user, so
  # notifiers with overlapping watched groups each fire independently.
  def processed_key(group_user_id, slot)
    return "#{PROCESSED_PREFIX}#{group_user_id}" if slot == 1

    "#{PROCESSED_PREFIX}#{group_user_id}_notifier_#{slot}"
  end

  def already_processed?(group_user_id, slot)
    PluginStore.get(PLUGIN_NAME, processed_key(group_user_id, slot)).present?
  end

  def mark_processed!(group_user_id, slot)
    PluginStore.set(PLUGIN_NAME, processed_key(group_user_id, slot), "1")
  end

  # Builds the list of configured, active notifiers. A slot is only active
  # if it has at least one watched group configured, so notifiers 2-5 are
  # entirely opt-in and require no setup if unused.
  def active_notifiers
    NOTIFIER_SLOTS.filter_map do |slot|
      watched_group_ids = configured_group_ids(setting_name(slot, :groups))

      next if watched_group_ids.blank?

      recipient_usernames =
        configured_recipient_usernames(setting_name(slot, :recipient_usernames))
      recipient_group_names =
        configured_recipient_group_names(setting_name(slot, :recipient_groups))

      if recipient_usernames.blank? && recipient_group_names.blank?
        Rails.logger.warn(
          "[#{PLUGIN_NAME}] Notifier ##{slot} has watched groups configured " \
          "but no valid recipients. Skipping it this run."
        )

        next
      end

      {
        slot: slot,
        watched_group_ids: watched_group_ids,
        recipient_usernames: recipient_usernames,
        recipient_group_names: recipient_group_names,
        pm_title: SiteSetting.public_send(setting_name(slot, :pm_title)),
        pm_body: SiteSetting.public_send(setting_name(slot, :pm_body))
      }
    end
  end

  # Iterates the given GroupUser scope in ascending (created_at, id) order,
  # in batches, and yields each record.
  #
  # ActiveRecord's #find_each ignores any custom .order and forces primary-key
  # ordering, which would break the chronological processing this plugin
  # relies on. Keyset pagination on (created_at, id) keeps the intended order
  # while still loading records in bounded batches.
  #
  # The scope passed in must NOT already carry an .order clause.
  def each_membership_ordered(scope, batch_size:)
    last_created_at = nil
    last_id = nil

    loop do
      batch = scope

      if last_created_at.present?
        batch =
          batch.where(
            "group_users.created_at > :created_at OR " \
            "(group_users.created_at = :created_at AND group_users.id > :id)",
            created_at: last_created_at,
            id: last_id
          )
      end

      records = batch.order(:created_at, :id).limit(batch_size).to_a

      break if records.empty?

      records.each { |group_user| yield group_user }

      last_record = records.last
      last_created_at = last_record.created_at
      last_id = last_record.id

      break if records.size < batch_size
    end
  end

  def create_notification!(group_user, notifier)
    user = group_user.user
    group = group_user.group

    return :skipped if user.blank? || group.blank?
    return :already_processed if already_processed?(group_user.id, notifier[:slot])

    variables = {
      username: user.username,
      group_name: group.name,
      added_at: group_user.created_at.in_time_zone.iso8601
    }

    post_options = {
      archetype: Archetype.private_message,
      title: render_template(notifier[:pm_title], variables),
      raw: render_template(notifier[:pm_body], variables)
    }

    if notifier[:recipient_usernames].present?
      post_options[:target_usernames] = notifier[:recipient_usernames].join(",")
    end

    if notifier[:recipient_group_names].present?
      post_options[:target_group_names] = notifier[:recipient_group_names].join(",")
    end

    creator = PostCreator.new(Discourse.system_user, post_options)
    post = creator.create

    if post.blank?
      error_message = creator.errors.full_messages.join(", ")
      error_message = "unknown error" if error_message.blank?

      Rails.logger.warn(
        "[#{PLUGIN_NAME}] Notifier ##{notifier[:slot]} failed to create " \
        "notification PM for GroupUser ##{group_user.id}: #{error_message}"
      )

      return :failed
    end

    # This is intentionally written only after PostCreator succeeds.
    mark_processed!(group_user.id, notifier[:slot])

    :success
  rescue StandardError => e
    Rails.logger.error(
      "[#{PLUGIN_NAME}] Notifier ##{notifier[:slot]} exception processing " \
      "GroupUser ##{group_user.id}: #{e.class}: #{e.message}\n" \
      "#{Array(e.backtrace).first(10).join("\n")}"
    )

    :failed
  end

  def check!
    return unless SiteSetting.added_to_group_notifier_enabled

    DistributedMutex.synchronize(
      LOCK_NAME,
      validity: LOCK_VALIDITY
    ) do
      perform_check!
    end
  rescue DistributedMutex::MaximumAttemptsExceeded
    Rails.logger.info(
      "[#{PLUGIN_NAME}] Another notifier check is already running; skipping."
    )
  end

  def perform_check!
    notifiers = active_notifiers

    return if notifiers.blank?

    checked_from = read_last_checked_at
    checked_until = Time.zone.now

    earliest_failure_time = nil

    notifiers.each do |notifier|
      # The >= boundary deliberately creates a small overlap between runs.
      # Processed markers prevent duplicate notifications for rows in that
      # overlap, while reducing the chance of missing records with identical
      # created_at timestamps.
      memberships =
        GroupUser
          .where(group_id: notifier[:watched_group_ids])
          .where(
            "group_users.created_at >= ? AND group_users.created_at <= ?",
            checked_from,
            checked_until
          )
          .includes(:user, :group)

      each_membership_ordered(memberships, batch_size: BATCH_SIZE) do |group_user|
        result = create_notification!(group_user, notifier)

        next unless result == :failed

        membership_time = group_user.created_at.in_time_zone

        if earliest_failure_time.blank? ||
            membership_time < earliest_failure_time
          earliest_failure_time = membership_time
        end
      end
    end

    # Failed records remain inside the polling window and will be retried.
    # Successful records are protected by their processed markers.
    write_last_checked_at(earliest_failure_time || checked_until)
  end
end
