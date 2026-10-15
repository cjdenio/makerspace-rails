module Error
  class DeviseFailure < Devise::FailureApp
    def respond
      if request.format == :json
        json_error_response
      else
        super
      end
    end

    def json_error_response
      self.status = 401
      self.content_type = 'application/json'
      self.response_body = { message: i18n_message }.to_json

      # Notify Slack when a revoked member attempts to log in
      if warden_message == :revoked
        notify_revoked_login_attempt
      end
    end

    private

    def notify_revoked_login_attempt
      member = find_member_by_email
      return unless member

      ::Service::SlackConnector.send_slack_message(
        "🚫 Revoked member #{member.fullname} attempted portal login",
        ::Service::SlackConnector.logs_channel
      )
    rescue => e
      Rails.logger.error("DeviseFailure: Slack notify failed: #{e.message}")
    end

    def find_member_by_email
      email = request.params.dig('member', 'email') ||
              request.params['email']
      Member.find_by(email: email&.strip&.downcase) if email.present?
    end
  end
end
