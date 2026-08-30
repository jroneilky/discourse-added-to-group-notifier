module Jobs
  class GroupAddNotifierCheck < ::Jobs::Scheduled
    every 5.minutes

    def execute(args)
      return unless SiteSetting.added_to_group_notifier_enabled
      ::AddedToGroupNotifier.check!
    end
  end
end
