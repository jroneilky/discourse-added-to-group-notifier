# name: discourse-added-to-group-notifier
# about: Sends a PM (from the system user) to configured recipients when a user is added to one of a configured list of groups. Polls the DB on a schedule rather than relying on Discourse's user_added_to_group event, so it works reliably even when membership changes come from bulk/dynamic-group syncs that bypass that event.
# version: 0.3
# authors: jronielky

enabled_site_setting :added_to_group_notifier_enabled

module ::AddedToGroupNotifier
  PLUGIN_NAME = "discourse-added-to-group-notifier"
  LAST_CHECKED_AT_KEY = "last_checked_at"
  PROCESSED_PREFIX = "processed_group_user_"
  LOCK_NAME = "discourse-added-to-group-notifier-check"
  LOCK_VALIDITY = 10.minutes

  module_function

  def render_template(template, vars)
    template.to_s.gsub(/%\{(\w+)\}/) do
      key = Regexp.last_match(1).to_sym

      if vars.key?(key)
        vars[key].to_s
      else
        Rails.logger.warn(
          "[#{PLUGIN_NAME}] Unknown template variable: #{key}"
        )

        "%{#{key}}"
      end
    end
  end

  def configured_group_ids(setting_name)
    map_method = "#{setting_name}_map"

    if SiteSetting.respond_to?(map_method)
      Array(SiteSetting.public_send(map_method))
        .map(&:to_i)
        .reject(&:zero?)
    else
      # Compatibility fallback for older Discourse versions.
      SiteSetting.public_send(setting_name)
        .to_s
        .split("|")
        .map(&:to_i)
        .reject(&:zero?)
    end
  end

  def configured_recipient_usernames
    configured =
      SiteSetting
        .added_to_group_notifier_recipient_usernames
        .to_s
        .split("|")
        .map(&:strip)
        .reject(&:blank?)

    return [] if configured.blank?

    # Resolve usernames through username_lower, then use the canonical
    # username stored by Discourse when passing targets to PostCreator.
    users =
      User
        .where(username_lower: configured.map(&:downcase))
        .pluck(:username)

    missing =
      configured.reject do |username|
        users.any? { |resolved| resolved.casecmp?(username) }
      end

    if missing.present?
      Rails.logger.warn(
        "[#{PLUGIN_NAME}] Ignoring unknown recipient usernames: #{missing.join(", ")}"
      )
    end

    users.uniq
  end

  def configured_recipient_group_names
    group_ids =
      configured_group_ids(:added_to_group_notifier_recipient_groups)

    return [] if group_ids.blank?

    Group.where(id: group_ids).pluck(:name).compact.uniq
  end

  def last_checked_at
    stored = PluginStore.get(PLUGIN_NAME, LAST_CHECKED_AT_KEY)

    return 10.minutes.ago if stored.blank?

    Time.zone.parse(stored.to_s)
  rescue ArgumentError, TypeError
    Rails.logger.warn(
      "[#{PLUGIN_NAME}] Invalid stored last_checked_at value #{stored.inspect}; " \
      "falling back to ten minutes ago"
    )

    10.minutes.ago
  end

  def save_last_checked_at(time)
    PluginStore.set(
      PLUGIN_NAME,
      LAST_CHECKED_AT_KEY,
      time.iso8601(6)
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

  def build_post_options(user, group)
    vars = {
      username: user.username,
      group_name: group.name,
      added_at: Time.zone.at(group_user_created_at).iso8601
    }

    recipient_usernames = configured_recipient_usernames
    recipient_group_names = configured_recipient_group_names

    options = {
      archetype: Archetype.private_message,
      title: render_template(
        SiteSetting.added_to_group_notifier_pm_title,
        vars
      ),
      raw: render_template(
        SiteSetting.added_to_group_notifier_pm_body,
        vars
      )
    }

    if recipient_usernames.present?
      options[:target_usernames] = recipient_usernames.join(",")
    end

    if recipient_group_names.present?
      options[:target_group_names] = recipient_group_names.join(",")
    end

    options
  end

  # This method is set immediately before build_post_options is called so
  # that the template can use the GroupUser creation timestamp.
  def group_user_created_at
    Thread.current[:added_to_group_notifier_group_user_created_at] || Time.zone.now
  end

  def send_notification!(group_user, recipient_usernames, recipient_group_names)
    user = group_user.user
    group = group_user.group

    return :skip if user.blank? || group.blank?

    return :already_processed if already_processed?(group_user.id)

    vars = {
      username: user.username,
      group_name: group.name,
      added_at: group_user.created_at.in_time_zone.iso8601
    }

    options = {
      archetype: Archetype.private_message,
      title: render_template(
        SiteSetting.added_to_group_notifier_pm_title,
        vars
      ),
      raw: render_template(
        SiteSetting.added_to_group_notifier_pm_body,
        vars
      )
    }

    if recipient_usernames.present?
      options[:target_usernames] = recipient_usernames.join(",")
    end

    if recipient_group_names.present?
      options[:target_group_names] = recipient_group_names.join(",")
    end

    creator = PostCreator.new(Discourse.system_user, options)
    post = creator.create

    if post.blank?
      errors = creator.errors.full_messages.join(", ")

      Rails.logger.warn(
        "[#{PLUGIN_NAME}] Failed to create PM for GroupUser ##{group_user.id}: " \
        "#{errors.presence || "unknown error"}"
      )

      return :failed
    end

    # Mark only after PostCreator successfully creates the PM. This prevents
    # normal validation failures from being permanently lost.
    mark_processed!(group_user.id)

    :success
  rescue StandardError => e
    Rails.logger.error(
      "[#{PLUGIN_NAME}] Exception while processing GroupUser ##{group_user.id}: " \
      "#{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}"
    )

    :failed
  end

  def check!
    return unless SiteSetting.added_to_group_notifier_enabled

    # Prevent overlapping Sidekiq executions from processing the same rows.
    DistributedMutex.synchronize(LOCK_NAME, validity: LOCK_VALIDITY) do
      perform_check!
    end
  rescue DistributedMutex::MaximumAttemptsExceeded
    Rails.logger.info(
      "[#{PLUGIN_NAME}] Another check is already running; skipping this run"
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
        "[#{PLUGIN_NAME}] Enabled but no valid recipients are configured; skipping"
      )

      return
    end

    checked_from = last_checked_at
    checked_until = Time.zone.now

    memberships =
      GroupUser
        .where(group_id: watched_group_ids)
        .where(
          "created_at >= ? AND created_at <= ?",
          checked_from,
          checked_until
        )
        .includes(:user, :group)
        .order(:created_at, :id)

    earliest_failure_time = nil

    memberships.find_each(batch_size: 100) do |group_user|
      result =
        send_notification!(
          group_user,
          recipient_usernames,
          recipient_group_names
        )

      if result == :failed
        timestamp = group_user.created_at.in_time_zone

        if earliest_failure_time.blank? || timestamp < earliest_failure_time
          earliest_failure_time = timestamp
        end
      end
    end

    # If any message failed, move the cursor back to the earliest failed
    # membership. Previously successful rows are protected by processed keys,
    # while failed rows will be retried on the next run.
    save_last_checked_at(earliest_failure_time || checked_until)
  end
end
