# frozen_string_literal: true

module Jobs
  class AddedToGroupNotifierCheck < ::Jobs::Scheduled
    every 5.minutes

    def execute(_args)
      return unless SiteSetting.added_to_group_notifier_enabled

      ::AddedToGroupNotifier.check!
    end
  end
end
