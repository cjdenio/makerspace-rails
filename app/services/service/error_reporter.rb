require 'active_support/parameter_filter'

module Service
  class ErrorReporter
    SENSITIVE_CONTEXT_KEYS = %i[response_url webhook_url].freeze

    def self.notify(error, context: {})
      Rails.logger.error(log_message(error, context))
      return unless defined?(Honeybadger)

      context.empty? ? Honeybadger.notify(error) : Honeybadger.notify(error, context: context)
    end

    def self.log_message(error, context)
      error_details = if error.respond_to?(:message)
        "#{error.class}: #{error.message}"
      else
        error.to_s
      end

      message = "[ErrorReporter] #{error_details}"
      unless context.empty?
        filtered_context = parameter_filter.filter(context)
        message += " | context: #{filtered_context.inspect}"
      end
      message
    end

    def self.parameter_filter
      configured_filters = Array(Rails.application.config.filter_parameters)
      ActiveSupport::ParameterFilter.new(configured_filters + SENSITIVE_CONTEXT_KEYS)
    end
    private_class_method :log_message, :parameter_filter
  end
end
