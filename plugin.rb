# name: discourse-added-to-group-notifier
# about: Sends a PM (from the system user) to configured recipients when a user is added to one of a configured list of groups. Polls the DB on a schedule rather than relying on Discourse's user_added_to_group event, so it works reliably even when membership changes come from bulk/dynamic-group syncs that bypass that event.
# version: 0.4
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

  module_function

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

  def configured_recipient_usernames
    configured_names =
      SiteSetting
        .added_to_group_notifier_recipient_usernames
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
        "[#{PLUGIN_NAME}] Ignoring unknown recipient usernames: " \
        "#{missing_names.join(", ")}"
      )
    end

    resolved_names.uniq
  rescue StandardError => e
    Rails.logger.error(
      "[#{PLUGIN_NAME}] Could not resolve recipient usernames: " \
      "#{e.class}: #{e.message}"
    )

    []
  end

  def configured_recipient_group_names
    group_ids =
      configured_group_ids(:added_to_group_notifier_recipient_groups)

    return [] if group_ids.blank?

    existing_groups =
      Group
        .where(id: group_ids)
        .pluck(:id, :name)
        .to_h

    missing_ids = group_ids - existing_groups.keys

    if missing_ids.present?
      Rails.logger.warn(
        "[#{PLUGIN_NAME}] Ignoring nonexistent recipient group IDs: " \
        "#{missing_ids.join(", ")}"
      )
    end

    group_ids.filter_map { |group_id| existing_groups[group_id] }.uniq
  rescue StandardError => e
    Rails.logger.error(
      "[#{PLUGIN_NAME}] Could not resolve recipient groups: " \
      "#{e.class}: #{e.message}"
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

  def processed_key(group_user_id)
    "#{PROCESSED_PREFIX}#{group_user_id}"
  end

  def already_processed?(group_user_id)
    PluginStore.get(PLUGIN_NAME, processed_key(group_user_id)).present?
  end

  def mark_processed!(group_user_id)
    PluginStore.set(
      PLUGIN_NAME,
      processed_key(group_user_id),
      "1"
    )
  end

  def create_notification!(group_user, recipient_usernames, recipient_group_names)
    user = group_user.user
    group = group_user.group

    return :skipped if user.blank? || group.blank?
    return :already_processed if already_processed?(group_user.id)

    variables = {
      username: user.username,
      group_name: group.name,
      added_at: group_user.created_at.in_time_zone.iso8601
    }

    post_options = {
      archetype: Archetype.private_message,
      title: render_template(
        SiteSetting.added_to_group_notifier_pm_title,
        variables
      ),
      raw: render_template(
        SiteSetting.added_to_group_notifier_pm_body,
        variables
      )
    }

    if recipient_usernames.present?
      post_options[:target_usernames] = recipient_usernames.join(",")
    end

    if recipient_group_names.present?
      post_options[:target_group_names] = recipient_group_names.join(",")
    end

    creator = PostCreator.new(Discourse.system_user, post_options)
    post = creator.create

    if post.blank?
      error_message = creator.errors.full_messages.join(", ")
      error_message = "unknown error" if error_message.blank?

      Rails.logger.warn(
        "[#{PLUGIN_NAME}] Failed to create notification PM for " \
        "GroupUser ##{group_user.id}: #{error_message}"
      )

      return :failed
    end

    # This is intentionally written only after PostCreator succeeds.
    mark_processed!(group_user.id)

    :success
  rescue StandardError => e
    Rails.logger.error(
      "[#{PLUGIN_NAME}] Exception processing GroupUser ##{group_user.id}: " \
      "#{e.class}: #{e.message}\n" \
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
    watched_group_ids =
      configured_group_ids(:added_to_group_notifier_groups)

    return if watched_group_ids.blank?

    recipient_usernames = configured_recipient_usernames
    recipient_group_names = configured_recipient_group_names

    if recipient_usernames.blank? && recipient_group_names.blank?
      Rails.logger.warn(
        "[#{PLUGIN_NAME}] The plugin is enabled, but no valid recipients " \
        "are configured. Skipping this run."
      )

      return
    end

    checked_from = read_last_checked_at
    checked_until = Time.zone.now

    # The >= boundary deliberately creates a small overlap between runs.
    # Processed markers prevent duplicate notifications for rows in that
    # overlap, while reducing the chance of missing records with identical
    # created_at timestamps.
    memberships =
      GroupUser
        .where(group_id: watched_group_ids)
        .where(
          "group_users.created_at >= ? AND group_users.created_at <= ?",
          checked_from,
          checked_until
        )
        .includes(:user, :group)
        .order(:created_at, :id)

    earliest_failure_time = nil

    memberships.find_each(batch_size: BATCH_SIZE) do |group_user|
      result =
        create_notification!(
          group_user,
          recipient_usernames,
          recipient_group_names
        )

      next unless result == :failed

      membership_time = group_user.created_at.in_time_zone

      if earliest_failure_time.blank? ||
          membership_time < earliest_failure_time
        earliest_failure_time = membership_time
      end
    end

    # Failed records remain inside the polling window and will be retried.
    # Successful records are protected by their processed markers.
    write_last_checked_at(earliest_failure_time || checked_until)
  end
end
