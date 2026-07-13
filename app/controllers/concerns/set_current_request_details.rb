
module SetCurrentRequestDetails
  extend ActiveSupport::Concern
  # Adds support for Cloudflare headers
  CLOUDFLARE_CLIENT_IP_HEADERS = [
    'CF-Connecting-IP',
    'True-Client-IP'
  ].freeze

  included do
    before_action do
      Current.url = request.url
      Current.method = request.method
      Current.params = request.params
      Current.request_id = request.uuid
      Current.user_agent = request.user_agent
      Current.ip_address = request.ip
      Current.ip_address = current_request_ip_address
    end
  end

  private

  def current_request_ip_address
    cloudflare_client_ip_address || request.ip
  end

  def cloudflare_client_ip_address
    return unless cloudflare_request?

    CLOUDFLARE_CLIENT_IP_HEADERS.filter_map do |header|
      request.headers[header].presence
    end.first
  end

  def cloudflare_request?
    request.respond_to?(:cloudflare?) && request.cloudflare?
  end
end
