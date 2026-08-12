require_relative 'custom_error'
require_relative 'helpers/render'

module Error
  module ErrorHandler
    def self.included(clazz)
      include ::Service::SlackConnector
      clazz.class_eval do
        # rescue_from StandardError do |e|
        #   if Rails.env.production?
        #     message = "Unhandled Error: #{e.message} #{e.backtrace}"
        #     slack_alert(:interal_server_error, 500, message)
        #     respond(:interal_server_error, 500, "Internal Server Error")
        #   else
        #     raise e
        #   end
        # end
        rescue_from ::Mongoid::Errors::MongoidError do |e|
          honeybadger_notify(e)
          slack_alert(:interal_server_error, 500, e.summary || "Internal Server Error")
          respond(:interal_server_error, 500, e.summary || "Internal Server Error")
        end
        rescue_from ::Mongoid::Errors::Validations do |e|
          slack_alert(:unprocessable_content, 422, e.summary || "Internal Server Error")
          respond(:unprocessable_content, 422, e.summary || "Internal Server Error")
        end
        rescue_from ::Mongoid::Errors::DocumentNotFound do |e|
          slack_alert(:not_found, 404, e.problem || "Resource not found")
          respond(:not_found, 404,  e.problem || "Resource not found")
        end
        rescue_from ::ActionController::InvalidAuthenticityToken do |e|
          respond(:unauthorized, 401, "Unauthorized")
        end
        rescue_from ::ActionController::ParameterMissing do |e|
          slack_alert(:unprocessable_content, 422, e.message)
          respond(:unprocessable_content, 422, e.message)
        end
        rescue_from ::Braintree::NotFoundError do |e|
          slack_alert(:not_found, 404, "Braintree resource not found")
          respond(:not_found, 404, "Braintree resource not found")
        end
        rescue_from CustomError do |e|
          Rails.logger.warn(
            "[RequestRejected] method=#{request.method} path=#{request.path} " \
            "member_id=#{current_member&.id || 'anonymous'} status=#{e.error} reason=#{e.message}"
          )
          honeybadger_notify(e) if e.error.to_i >= 500
          slack_alert(e.status, e.error, e.message)
          respond(e.status, e.error, e.message)
        end
      end
    end

    private

    def respond(_error, _status, _message)
      log_forbidden_to_stderr(_message) if _status.to_i == 403
      log_not_found_file_lookup_context if _status.to_i == 404 && respond_to?(:log_not_found_file_lookup_context, true)
      json = Error::Helpers::Render.json(_error, _status, _message)
      render json: json, status: _status and return
    end

    def log_forbidden_to_stderr(message)
      return unless ENV['RAILS_LOG_TO_STDERR'].present?
      return unless self.try(:current_member)

      path = request.try(:path).to_s
      return unless path.start_with?('/api')

      STDERR.puts(
        "[403] #{request.method} #{path} member_id=#{current_member.id} " \
        "email=#{current_member.email} role=#{current_member.role} reason=#{message}"
      )
    rescue => e
      Rails.logger.warn("Failed to log 403 to STDERR: #{e.message}")
    end

    # Sends the exception to Honeybadger with request context.
    # Only called for 5xx errors — 4xx are expected/noisy and don't belong there.
    # Jobs, models, and FirebaseAuthController notify Honeybadger independently
    # so this only covers controller-layer errors caught by rescue_from.
    def honeybadger_notify(exception)
      Honeybadger.notify(
        exception,
        context: {
          user:       self.try(:current_member)&.id&.to_s,
          user_email: self.try(:current_member)&.email,
          url:        Current.url,
          method:     Current.method,
          params:     Current.params,
          request_id: Current.request_id,
        }
      )
    rescue => notify_err
      # Never let Honeybadger itself break the error response
      Rails.logger.error("[ErrorHandler] Honeybadger.notify failed: #{notify_err.message}")
    end

    def slack_alert(_error, _status, _message)
      if _status >= 500
        error_type = "Server"
      elsif _status >= 400
        error_type = "Request"
      else
        error_type = "Unknown"
      end
      user = self.try(:current_member) ? "User #{current_member.fullname}" : "Not authenticated"

      # Dont send slack messages for unauthenticated 404s. We receive these from web crawlers
      # and malicious users. They only serve to clog logs.
      unless !self.try(:current_member) && _status.to_i == 404
        message = "*#{error_type} Error* \n- user: #{user} \n- status: #{_status} \n- error: #{_error} \n- message: #{_message}"
        
        if Current.request_id 
          message += "\n URL: #{Current.method} #{Current.url} \n #{Current.params}"
        end

        # @channel on server errors
        if _status.to_i >= 500 
          message = "<!channel> " + message
        end

        enque_message(message, ::Service::SlackConnector.logs_channel)
        SlackMessagesJob.perform_later(Current.request_id)
      end
    end
  end
end
