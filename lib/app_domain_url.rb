module AppDomainUrl
  SECURE_TLDS = %w[com net org].freeze

  module_function

  def host(domain = ENV["APP_DOMAIN"])
    normalized_host = domain.to_s.strip
      .sub(%r{\A(?:(?:https?):\/\/)+}i, "")
      .sub(%r{/+\z}, "")
    normalized_host.empty? ? "localhost" : normalized_host
  end

  def base_url(domain = ENV["APP_DOMAIN"], environment: nil)
    normalized_host = host(domain)
    protocol = secure_protocol?(normalized_host, environment: environment) ?
      "https" :
      "http"
    "#{protocol}://#{normalized_host}"
  end

  def secure_protocol?(domain, environment: nil)
    production_environment?(environment) || secure_tld?(domain)
  end

  def production_environment?(environment)
    [
      environment,
      ENV["ENVIRONMENT"],
      ENV["RAILS_ENV"],
      ENV["RACK_ENV"]
    ].compact.any? { |value| value.to_s.casecmp("production").zero? }
  end

  def secure_tld?(domain)
    authority = domain.to_s.split("/", 2).first.to_s
    hostname = authority.sub(/\A.*@/, "")
      .sub(/:\d+\z/, "")
      .delete_suffix(".")
      .downcase
    SECURE_TLDS.any? { |tld| hostname.end_with?(".#{tld}") }
  end
end
