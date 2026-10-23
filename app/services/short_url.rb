require "ipaddr"

class ShortUrl
  class InvalidTarget < StandardError; end
  class Unavailable < StandardError; end
  ALPHABET = "23456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".freeze
  SPACE = 34**10
  TTL = 86_400
  KEY_PREFIX = "shortcodes:v1:"
  CODE = /\A[2-9A-Z]{10}\z/
  PUBLIC_PATH = %r{\A/(?:api/)?(shop|tool)/([a-f0-9]{24})/public\.html\z}
  PLURAL_PATH = %r{\A/(shops|tools)/([a-f0-9]{24})/public\.html\z}
  CHECKOUT_PATH = %r{\A/tools/([a-f0-9]{24})/request-checkout\z}
  BOUNTY_PATH = %r{\A/volunteer/tasks/([a-f0-9]{24})\z}
  RENTAL_PATH = %r{\A/rentals/spots/([a-f0-9]{24})\z}

  def self.base_url(fallback_host: nil)
    domain = (ENV.fetch("APP_DOMAIN") { nil }).to_s.strip
    fallback = domain.empty?
    authority = fallback ? fallback_host.to_s.strip : AppDomainUrl.host(domain)
    # Only an authority is accepted: never paths, credentials, queries or headers.
    raise Unavailable unless authority.match?(%r{\A(?:[a-z0-9.-]+|\[[a-f0-9:]+\])(?::[0-9]+)?\z}i)
    uri = URI.parse("https://#{authority}")
    hostname = uri.hostname.downcase.delete_suffix(".")
    raise Unavailable unless (1..65_535).cover?(uri.port)
    raise Unavailable if hostname == "localhost" || hostname.end_with?(".localhost")
    begin
      address = IPAddr.new(hostname).native
      raise Unavailable if address.to_i.zero? || IPAddr.new("127.0.0.0/8").include?(address) || address == IPAddr.new("::1")
    rescue IPAddr::InvalidAddressError
      # Reject ambiguous numeric hosts such as the integer form of loopback.
      raise Unavailable if hostname.match?(/\A[0-9.]+\z/)
      raise Unavailable unless hostname.split(".").all? { |label| label.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/) }
    end
    Rails.logger.warn("[ShortUrl] APP_DOMAIN missing or blank; using validated request host") if fallback
    AppDomainUrl.base_url(authority, environment: Rails.env)
  rescue URI::Error
    raise Unavailable
  end

  def self.normalize(value, origin: base_url)
    value = value.to_s
    uri = URI.parse(value)
    base = URI.parse(origin)
    if value.start_with?("/") && !value.start_with?("//")
      uri = URI.join(base.to_s, value)
    end
    raise InvalidTarget unless uri.is_a?(URI::HTTP) &&
      uri.scheme == base.scheme && uri.host&.downcase == base.host&.downcase && uri.port == base.port &&
      !uri.userinfo && !uri.query && !uri.fragment && supported_path?(uri.path)
    "#{base.to_s.sub(%r{/+\z}, '')}#{uri.path}"
  rescue URI::Error, KeyError
    raise InvalidTarget
  end

  def self.supported_path?(path)
    BOUNTY_PATH.match?(path) || PUBLIC_PATH.match?(path) || PLURAL_PATH.match?(path) || CHECKOUT_PATH.match?(path) || RENTAL_PATH.match?(path)
  end

  def self.visible!(url)
    path = URI.parse(url).path
    if (match = BOUNTY_PATH.match(path))
      raise PublicCatalog::Unavailable unless VolunteerTask.where(id: match[1]).exists?
    elsif (match = PUBLIC_PATH.match(path)) || (match = PLURAL_PATH.match(path))
      match[1].start_with?("shop") ? PublicCatalog.shop(match[2]) : PublicCatalog.tool(match[2])
    elsif (match = CHECKOUT_PATH.match(path))
      PublicCatalog.tool(match[1])
    elsif (match = RENTAL_PATH.match(path))
      raise PublicCatalog::Unavailable unless RentalSpot.where(id: match[1], active: true).exists?
    else
      raise InvalidTarget
    end
  rescue Mongo::Error => error
    Rails.logger.error("[ShortUrl] visibility lookup failed: #{error.class}")
    raise Unavailable
  end

  def self.encode(number)
    value = number % SPACE
    result = ""
    10.times { result.prepend(ALPHABET[value % 34]); value /= 34 }
    result
  end

  def self.allocate(value, origin: base_url)
    target = normalize(value, origin: origin)
    stored_target = URI.parse(target).path
    # Read legacy absolute mappings as well as the new origin-independent values.
    equivalent_targets = [stored_target, target]
    verify_indexes!
    existing = Shortcode.where(:target_url.in => equivalent_targets).first
    return publish(existing, origin: origin) if existing
    number = Digest::SHA256.hexdigest(target).to_i(16) % SPACE
    SPACE.times do
      code = encode(number)
      # Cache is advisory during allocation; Mongo uniquely owns every code.
      cache_target = cached(code, origin: origin)
      existing = Shortcode.where(code: code).first
      if cache_target && ![cache_target, URI.parse(cache_target).path].include?(existing&.target_url)
        Rails.logger.warn("[ShortUrl] stale cache during allocation code=#{code}")
      end
      return publish(existing, origin: origin) if existing && equivalent_targets.include?(existing.target_url)
      unless existing
        begin
          return publish(Shortcode.create!(code: code, target_url: stored_target), origin: origin)
        rescue Mongo::Error::OperationFailure => error
          raise unless error.code == 11000
          existing = Shortcode.where(:target_url.in => equivalent_targets).first
          return publish(existing, origin: origin) if existing
        end
      end
      Rails.logger.info("[ShortUrl] allocation collision code=#{code}")
      number = (number + 1) % SPACE
    end
    raise Unavailable
  rescue Mongo::Error => error
    Rails.logger.error("[ShortUrl] allocation failed: #{error.class}")
    raise Unavailable
  end

  def self.verify_indexes!(force: false)
    return if @indexes_verified && !force
    indexes = Shortcode.current_indexes
    if indexes.empty?
      # Create the collection with both unique indexes before its first mapping.
      Shortcode.ensure_indexes!
      indexes = Shortcode.current_indexes
    end
    valid = %w[code target_url].all? do |field|
      indexes.any? { |index| Shortcode.full_unique_index?(index, field) }
    end
    unless valid
      Rails.logger.error("[ShortUrl] unique indexes missing; run rake shortcodes:ensure_indexes")
      raise Unavailable
    end
    @indexes_verified = true
  end

  def self.publish(record, origin: base_url)
    cache(record.code, record.target_url, origin: origin)
    { code: record.code, short_url: "#{origin}/L#{record.code}".upcase }
  end

  def self.resolve(code, origin: base_url)
    return nil unless CODE.match?(code.to_s)
    value = cached(code, origin: origin)
    return value if value
    record = Shortcode.where(code: code).only(:target_url).first
    return nil unless record
    value = normalize(record.target_url, origin: origin)
    cache(code, value, origin: origin)
    value
  rescue InvalidTarget
    nil
  rescue Mongo::Error => error
    Rails.logger.error("[ShortUrl] resolution failed: #{error.class}")
    raise Unavailable
  end

  def self.cached(code, origin: base_url)
    value = REDIS.get("#{KEY_PREFIX}#{code}")
    value.present? ? normalize(value, origin: origin) : nil
  rescue InvalidTarget
    nil
  rescue Redis::BaseError, IOError => error
    Rails.logger.warn("[ShortUrl] cache read failed: #{error.class}")
    nil
  end

  def self.cache(code, target, origin: base_url)
    REDIS.set("#{KEY_PREFIX}#{code}", URI.parse(normalize(target, origin: origin)).path, ex: TTL)
  rescue Redis::BaseError, IOError => error
    Rails.logger.warn("[ShortUrl] cache write failed: #{error.class}")
  end
end
