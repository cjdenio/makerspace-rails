class SlackReservationOutcomeJob < ApplicationJob
  queue_as :slack

  # The response URL is a private, short-lived Slack credential. Active Job's
  # normal lifecycle logging must not serialize it into application logs.
  self.log_arguments = false

  OPEN_TIMEOUT_SECONDS = 1
  READ_TIMEOUT_SECONDS = 2
  WRITE_TIMEOUT_SECONDS = 1

  def perform(message, response_url, slack_user_id)
    return if replace_response(response_url, message)

    Service::SlackConnector.send_slack_message(message, slack_user_id)
  rescue => error
    report_failure(error, phase: "Slack reservation outcome delivery", slack_user_id: slack_user_id)
  end

  private

  def replace_response(response_url, message)
    return false if response_url.blank?

    uri = URI.parse(response_url)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = {
      response_type: "ephemeral",
      replace_original: true,
      text: message
    }.to_json
    response = Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: OPEN_TIMEOUT_SECONDS,
      read_timeout: READ_TIMEOUT_SECONDS,
      write_timeout: WRITE_TIMEOUT_SECONDS
    ) { |http| http.request(request) }
    return true if response.is_a?(Net::HTTPSuccess)

    report_failure(
      "Slack reservation response replacement failed",
      phase: "Slack reservation response replacement",
      http_status: response.code
    )
    false
  rescue => error
    report_failure(error, phase: "Slack reservation response replacement")
    false
  end

  def report_failure(error, **context)
    Service::ErrorReporter.notify(error, context: context)
  rescue => reporting_error
    Rails.logger.error(
      "[SlackReservationError] action=deliver error=#{error.class} " \
      "reporting_error=#{reporting_error.class}"
    )
  end
end
