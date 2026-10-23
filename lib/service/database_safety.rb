require 'uri'

module Service
  module DatabaseSafety
    SAFE_NAME_PATTERN = /(dev|test)/i

    module_function

    def ensure_safe_mlab_uri!(operation: 'destructive database operation', mlab_uri: ENV['MLAB_URI'])
      mlab_uri = mlab_uri.to_s
      username, hostname, database_name = parsed_identity_components(mlab_uri)
      safe = [username, hostname, database_name].compact.any? do |value|
        value.match?(SAFE_NAME_PATTERN)
      end
      return true if safe

      message = if mlab_uri.present?
        "Refusing to run #{operation}: the MLAB_URI username, hostname, or database name must contain dev or test."
      else
        "Refusing to run #{operation}: MLAB_URI is not set; its username, hostname, or database name must contain dev or test."
      end

      Rails.logger.error(message) if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
      warn(message)
      raise message
    end

    def parsed_identity_components(mlab_uri)
      return [nil, nil, nil] if mlab_uri.blank?

      uri = URI.parse(mlab_uri)
      return [nil, nil, nil] unless %w[mongodb mongodb+srv].include?(uri.scheme)

      username = URI.decode_www_form_component(uri.user.to_s).presence
      hostname = uri.host.to_s.presence
      database_name = URI.decode_www_form_component(uri.path.to_s.split('/').last.to_s).presence
      [username, hostname, database_name]
    rescue URI::InvalidURIError, ArgumentError
      [nil, nil, nil]
    end
  end
end
