# Display metadata only. Never use this cache to authorize a mutation or reservation.
class AvailableShopCache
  TTL = 10_800
  VERSION = 1
  COLLATION = { locale: 'en', strength: 2 }.freeze
  Entry = Data.define(:id, :name, :slack_channel)
  class RefreshSuperseded < StandardError; end
  CACHE_ERRORS = [Redis::BaseError, IOError, SystemCallError].freeze

  GENERATION = <<~LUA.freeze
    redis.call('SET', KEYS[1], ARGV[1])
    return ARGV[1]
  LUA
  INVALIDATE = <<~LUA.freeze
    redis.call('SET', KEYS[1], ARGV[1])
    redis.call('DEL', KEYS[2])
    return 1
  LUA
  PUBLISH = <<~LUA.freeze
    if redis.call('GET', KEYS[1]) ~= ARGV[1] then return 0 end
    local now = redis.call('TIME')
    local remaining = tonumber(ARGV[3]) - (tonumber(now[1]) * 1000 + math.floor(tonumber(now[2]) / 1000))
    if remaining <= 0 then return 0 end
    redis.call('SET', KEYS[2], ARGV[2], 'PX', remaining)
    return 1
  LUA

  class << self
    def fetch
      cached = best_effort { decode(REDIS.get(data_key)) }
      return cached unless cached.nil?

      project(load_visible)
    end

    # These own the query: a partial/caller-supplied snapshot must never replace the list.
    def load_all
      load_records(Shop.all)
    end

    def load_visible
      load_records(Shop.where(:disabled.ne => true))
    end

    # Strict operator entry point; a failure must produce a nonzero task exit status.
    def refresh!
      invalidate!
      load_records(Shop.where(:disabled.ne => true), strict: true).then { |rows| project(rows) }
    end

    # Persistence already succeeded. Cache maintenance must not turn it into a failed write.
    def refresh
      refresh!
    rescue *CACHE_ERRORS, Mongo::Error, RefreshSuperseded => error
      warn_failure(error)
      nil
    end

    def invalidate!
      REDIS.eval(INVALIDATE, keys: [generation_key, data_key], argv: [SecureRandom.uuid])
    end

    def invalidate
      best_effort { invalidate! }
    end

    # For callback-bypassing imports/deletes. Refresh even if a batch only partly succeeds.
    # Transactional callers must invoke this outside the outer transaction.
    def with_bulk_changes
      invalidate
      yield
    ensure
      refresh
    end

    def find_by_channel(channel_id: nil, channel_name: nil)
      identifiers = [channel_id, channel_name].filter_map do |value|
        Service::SlackChannelCache.normalize_name(value).presence
      end
      return nil if identifiers.empty?

      fetch.find do |entry|
        entry.slack_channel.present? && identifiers.include?(Service::SlackChannelCache.normalize_name(entry.slack_channel))
      end
    end

    def data_key = "#{namespace}:data"
    def generation_key = "#{namespace}:generation"

    private

    def namespace
      "available_shops:v#{VERSION}:#{Rails.env}:#{Shop.collection.database.name}"
    end

    def load_records(criteria, strict: false)
      # Every complete query claims a generation, including index warming. A
      # slower earlier query cannot publish over a newer query or mutation.
      capture = -> { REDIS.eval(GENERATION, keys: [generation_key], argv: [SecureRandom.uuid]) }
      token = strict ? capture.call : best_effort(&capture)
      started_at = Time.now.to_f
      records = criteria.collation(COLLATION).order_by(name: :asc, id: :asc).to_a
      if token
        write = -> { publish(token, started_at, project(records)) }
        if strict
          raise RefreshSuperseded, 'Shop cache refresh superseded or expired; retry' unless write.call
        else
          best_effort(&write)
        end
      end
      records
    end

    def project(records)
      records.reject { |shop| shop.disabled == true }.map do |shop|
        Entry.new(id: shop.id.to_s.freeze, name: shop.name.to_s.freeze,
          slack_channel: shop.slack_channel&.dup&.freeze)
      end.freeze
    end

    def publish(token, started_at, entries)
      expires_at = ((started_at + TTL) * 1000).floor
      return false if expires_at <= (Time.now.to_f * 1000).floor

      payload = JSON.generate(version: VERSION, started_at: started_at, entries: entries.map(&:to_h))
      REDIS.eval(PUBLISH, keys: [generation_key, data_key], argv: [token, payload, expires_at]).to_i == 1
    end

    def decode(raw)
      return nil unless raw
      payload = JSON.parse(raw)
      return nil unless payload.is_a?(Hash) && payload['version'] == VERSION
      started_at, rows = payload.values_at('started_at', 'entries')
      return nil unless started_at.is_a?(Numeric) && started_at <= Time.now.to_f && started_at > Time.now.to_f - TTL
      return nil unless rows.is_a?(Array) && rows.all? do |row|
        row.is_a?(Hash) && row.keys.sort == %w[id name slack_channel] &&
          row['id'].is_a?(String) && BSON::ObjectId.legal?(row['id']) && row['name'].is_a?(String) &&
          (row['slack_channel'].nil? || row['slack_channel'].is_a?(String))
      end
      return nil unless rows.map { |row| row['id'] }.uniq.length == rows.length

      rows.map do |row|
        Entry.new(id: row['id'].freeze, name: row['name'].freeze, slack_channel: row['slack_channel']&.freeze)
      end.freeze
    rescue JSON::ParserError
      nil
    end

    def best_effort
      yield
    rescue *CACHE_ERRORS => error
      warn_failure(error)
      nil
    end

    def warn_failure(error)
      Rails.logger.warn("[AvailableShopCache] cache maintenance unavailable: #{error.class}")
    end
  end
end
