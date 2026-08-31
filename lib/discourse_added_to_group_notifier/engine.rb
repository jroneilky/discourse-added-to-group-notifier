# frozen_string_literal: true

module DiscourseAddedToGroupNotifier
  class Engine < ::Rails::Engine
    engine_name "discourse-added-to-group-notifier"
    isolate_namespace DiscourseAddedToGroupNotifier
  end
end
