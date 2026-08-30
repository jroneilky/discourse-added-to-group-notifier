# name: discourse-added-to-group-notifier
# about: Sends a PM (from the system user) to configured recipients when a user is added to one of a configured list of groups. Polls the DB on a schedule rather than relying on Discourse's user_added_to_group event, so it works reliably even when membership changes come from bulk/dynamic-group syncs that bypass that event.
# version: 0.2
# authors: jronielky

enabled_site_setting :added_to_group_notifier_enabled

module ::AddedToGroupNotifier
  PLUGIN_NAME = "discourse-added-to-group-notifier"

  # Replaces %{key} tokens in a template with values from vars.
  # Deliberately does not use Ruby's String#% so that a stray "%"
  # elsewhere in an admin-supplied template can't raise an error.
  def self.render_template(template, vars)
    template.to_s.gsub(/%\{(\w+)\}/) { vars[Regexp.last_match(1).to_sym].to_s }
  end

  def self.check!
    # Safely parse watched groups (handles both IDs and Names to future-proof against Discourse updates)
    watched_setting = SiteSetting.added_to_group_notifier_groups.to_s.split("|").map(&:strip).reject(&:blank?)
    return if watched_setting.blank?

    watched_group_ids = Group.where(id: watched_setting).or(Group.where(name: watched_setting)).pluck(:id)
    return if watched_group_ids.blank?

    recipient_usernames = SiteSetting.added_to_group_notifier_recipient_usernames.to_s.split("|").map(&:strip).reject(&:blank?)
    
    recipient_group_setting = SiteSetting.added_to_group_notifier_recipient_groups.to_s.split("|").map(&:strip).reject(&:blank?)
    recipient_group_names = recipient_group_setting.present? ? Group.where(id: recipient_group_setting).or(Group.where(name: recipient_group_setting)).pluck(:name) : []

    if recipient_usernames.blank? && recipient_group_names.blank?
      Rails.logger.warn("[discourse-added-to-group-notifier] Enabled but no recipients configured, skipping")
      return
    end

    last_checked = PluginStore.get(PLUGIN_NAME, "last_checked_at")
    last_checked = last_checked.present? ? Time.zone.parse(last_checked) : 10.minutes.ago
    now = Time.zone.now

    new_members = GroupUser
      .where(group_id: watched_group_ids)
      .where("created_at > ? AND created_at <= ?", last_checked, now)
      .includes(:user, :group)

    new_members.each do |gu|
      next if gu.user.blank? || gu.group.blank?

      vars = { username: gu.user.username, group_name: gu.group.name, added_at: gu.created_at.to_s }

      opts = {
        archetype: Archetype.private_message,
        title: render_template(SiteSetting.added_to_group_notifier_pm_title, vars),
        raw: render_template(SiteSetting.added_to_group_notifier_pm_body, vars),
      }
      opts[:target_usernames] = recipient_usernames.join(",") if recipient_usernames.present?
      opts[:target_group_names] = recipient_group_names.join(",") if recipient_group_names.present?

      # Use .create instead of .create! to ensure one failed PM doesn't crash the entire job
      creator = PostCreator.new(Discourse.system_user, opts)
      post = creator.create
      
      if post.blank?
        Rails.logger.warn("[discourse-added-to-group-notifier] Failed to create PM: #{creator.errors.full_messages.join(', ')}")
      end
    end

    PluginStore.set(PLUGIN_NAME, "last_checked_at", now.iso8601)
  end
end
