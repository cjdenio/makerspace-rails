require 'json'
require 'timeout'
require 'uri'

module Service
  class TurnstileVerifier
    ENDPOINT = 'https://challenges.cloudflare.com/turnstile/v0/siteverify'.freeze
    TIMEOUT_SECONDS = 20

    def initialize(token:, remote_ip:, connection: nil)
      @token = token.to_s
      @remote_ip = remote_ip.to_s
      @connection = connection || default_connection
    end

    def valid?
      return true if secret.blank?
      return false if @token.blank?

      response = Timeout.timeout(TIMEOUT_SECONDS) do
        @connection.post do |request|
          request.headers['Content-Type'] = 'application/x-www-form-urlencoded'
          request.body = URI.encode_www_form(
            secret: secret,
            response: @token,
            remoteip: @remote_ip
          )
        end
      end

      unless response.success?
        Rails.logger.error("[Turnstile] siteverify returned HTTP #{response.status}")
        return false
      end

      payload = JSON.parse(response.body)
      payload.is_a?(Hash) && payload['success'] == true
    rescue Timeout::Error, Faraday::TimeoutError => e
      Rails.logger.error(
        "[Turnstile] siteverify timed out after #{TIMEOUT_SECONDS} seconds: #{e.class}: #{e.message}"
      )
      true
    rescue Faraday::Error, JSON::ParserError => e
      Rails.logger.error("[Turnstile] siteverify failed: #{e.class}: #{e.message}")
      false
    end

    private

    def secret
      ENV['TURNSTILE_SECRET']
    end

    def default_connection
      Faraday.new(
        url: ENDPOINT,
        request: {
          timeout: TIMEOUT_SECONDS,
          open_timeout: TIMEOUT_SECONDS
        }
      )
    end
  end
end
