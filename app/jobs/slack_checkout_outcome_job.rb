class SlackCheckoutOutcomeJob < ApplicationJob
  queue_as :slack
  self.log_arguments = false

  OPEN_TIMEOUT_SECONDS = 0.5
  READ_TIMEOUT_SECONDS = 1
  WRITE_TIMEOUT_SECONDS = 0.5

  # Encrypt before enqueueing: even an adapter exception that prints its job
  # arguments cannot disclose the response URL. Never report raw exceptions.
  def self.enqueue(message, response_url, slack_user_id)
    token = encryptor.encrypt_and_sign(response_url.to_s)
    queued = perform_later(message, token, slack_user_id)
    report("enqueue") unless queued
    queued
  rescue => error
    report("enqueue", error_class: error.class.name)
    false
  end

  def self.encryptor
    key = Rails.application.key_generator.generate_key("slack_checkout_outcome", 32)
    ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm")
  end

  def self.report(phase, **context)
    Service::ErrorReporter.notify("Slack checkout outcome #{phase} failed", context: context.merge(phase: phase))
  rescue
    Rails.logger.error("[SlackCheckoutOutcome] failure reporting unavailable")
  end

  def perform(message, encrypted_response_url, slack_user_id)
    return if replace_response(message, encrypted_response_url)
    Service::SlackConnector.send_slack_message(message, slack_user_id)
  rescue => error
    self.class.report("DM", error_class: error.class.name, slack_user_id: slack_user_id)
  end

  private

  def replace_response(message, token)
    response_url = self.class.encryptor.decrypt_and_verify(token)
    raise ArgumentError if response_url.blank?
    uri = URI.parse(response_url)
    raise ArgumentError unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = { replace_original: true, response_type: "ephemeral", text: message }.to_json
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
      open_timeout: OPEN_TIMEOUT_SECONDS, read_timeout: READ_TIMEOUT_SECONDS,
      write_timeout: WRITE_TIMEOUT_SECONDS) { |http| http.request(request) }
    return true if response.is_a?(Net::HTTPSuccess)
    self.class.report("replacement", http_status: response.code)
    false
  rescue => error
    self.class.report("replacement", error_class: error.class.name)
    false
  end
end
