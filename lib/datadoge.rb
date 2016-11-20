require 'datadoge/version'
require 'gem_config'
require 'datadog/statsd'

module Datadoge
  include GemConfig::Base

  with_configuration do
    has :environments, classes: Array, default: ['production']
    has :host, classes: String, default: '127.0.0.1'
    has :port, classes: Integer, default: 8125
  end

  class Railtie < Rails::Railtie
    initializer 'datadoge.configure_rails_initialization' do |app|
      host = Datadoge.configuration.host
      port = Datadoge.configuration.port
      $statsd = Datadog::Statsd.new host, port

      ActiveSupport::Notifications.subscribe(/process_action.action_controller/) do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        controller = "controller:#{event.payload[:controller]}"
        action = "action:#{event.payload[:action]}"
        path = "path:#{event.payload[:controller]}/#{event.payload[:action]}"
        format = "format:#{event.payload[:format] || 'all'}"
        format = "format:all" if format == "format:*/*"
        host = "host:#{ENV['INSTRUMENTATION_HOSTNAME'] || Rails.application.class.parent_name}"
        status = event.payload[:status]
        tags = [path, action, controller, format, host]
        ActiveSupport::Notifications.instrument :performance, :action => :timing, :tags => tags, :measurement => "request.total_duration", :value => event.duration
        ActiveSupport::Notifications.instrument :performance, :action => :timing, :tags => tags,  :measurement => "database.query.time", :value => event.payload[:db_runtime]
        ActiveSupport::Notifications.instrument :performance, :action => :timing, :tags => tags,  :measurement => "web.view.time", :value => event.payload[:view_runtime]
        ActiveSupport::Notifications.instrument :performance, :tags => tags,  :measurement => "request.status.#{status}"
      end

      ActiveSupport::Notifications.subscribe(/performance/) do |name, start, finish, id, payload|
        send_event_to_statsd(name, payload) if Datadoge.configuration.environments.include?(Rails.env)
      end

      def send_event_to_statsd(name, payload)
        action = payload[:action] || :increment
        measurement = payload[:measurement]
        value = payload[:value]
        tags = payload[:tags]
        key_name = "#{name.to_s.capitalize}.#{measurement}"
        if action == :increment
          $statsd.increment key_name, :tags => tags
        else
          $statsd.histogram key_name, value, :tags => tags
        end
      end
    end
  end
end
