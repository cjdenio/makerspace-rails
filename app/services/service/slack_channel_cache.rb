module Service
  class SlackChannelCache
    CACHE_PREFIX = "slack:public_channel".freeze
    CACHE_ID_PREFIX = "slack:public_channel_id".freeze
    STATUS_KEY = "slack:public_channel_cache:status".freeze
    REBUILD_PREFIX = "slack:public_channel_cache:rebuild".freeze
    CACHE_TTL_SECONDS = 3000.hours.to_i
    PAGE_SIZE = 200
    CHANNEL_ID_PATTERN = /\A[CG][A-Z0-9]{8,}\z/.freeze
    PROMOTE_SCRIPT = <<~LUA.freeze
      local staged_count = tonumber(ARGV[1])
      local live_count = tonumber(ARGV[2])

      for index = 1, staged_count do
        if redis.call("EXISTS", KEYS[index]) == 0 then
          return redis.error_reply("Slack cache staging key missing: " .. KEYS[index])
        end
      end

      for index = 1, live_count do
        redis.call("DEL", KEYS[staged_count + index])
      end

      for index = 1, staged_count do
        redis.call("RENAME", KEYS[index], ARGV[index + 2])
      end

      local status_key = KEYS[staged_count + live_count + 1]
      redis.call(
        "SET",
        status_key,
        ARGV[staged_count + 3],
        "EX",
        ARGV[staged_count + 4]
      )
      return staged_count
    LUA

    class << self
      def normalize_name(value)
        raw_value = value.to_s.strip
        return raw_value if channel_id?(raw_value)

        raw_value.sub(/\A#+/, "").downcase
      end

      def channel_id?(value)
        value.to_s.match?(CHANNEL_ID_PATTERN)
      end

      def fetch(channel_name)
        name = normalize_name(channel_name)
        return nil if name.blank?

        raw = REDIS.get(cache_key(name))
        raw.present? ? JSON.parse(raw).with_indifferent_access : nil
      rescue Redis::BaseError, JSON::ParserError, TypeError => error
        Rails.logger.warn(
          "[SlackChannelCache] cache read failed name=#{name.inspect} " \
          "error=#{error.class}: #{error.message}"
        )
        nil
      end

      def lookup(channel_name, refresh_on_miss: false)
        name = normalize_name(channel_name)
        return nil if name.blank?

        fetch(name) || (refresh_until(name) if refresh_on_miss)
      end

      def refresh_all!
        count = scan_public_channels { |details| write(details) }
        write_status(count) unless count.nil?
        count
      end

      def rebuild!
        channels = []
        count = scan_public_channels { |details| channels << details }
        raise "Slack public-channel cache rebuild failed" if count.nil?

        staging_prefix = "#{REBUILD_PREFIX}:#{SecureRandom.hex(16)}"
        staged_keys = []
        staged_entries = cache_entries(channels).map do |identifier, details|
          key = "#{staging_prefix}:#{identifier}"
          staged_keys << key
          write(details, key: key, raise_on_error: true)
          [key, cache_key(identifier)]
        end
        live_keys = live_cache_keys
        promote_staged_cache!(staged_entries, live_keys, count)

        count
      rescue Redis::BaseError => error
        Rails.logger.warn(
          "[SlackChannelCache] Redis rebuild failed " \
          "error=#{error.class}: #{error.message}"
        )
        raise
      ensure
        cleanup_staging_keys(staged_keys)
      end

      def clear!
        keys = live_cache_keys
        keys.each_slice(500) { |batch| REDIS.del(*batch) } if keys.present?
        REDIS.del(STATUS_KEY)
        keys.length
      end

      def status
        metadata = parse_status(REDIS.get(STATUS_KEY))
        {
          available: true,
          total_channels: REDIS.scan_each(
            match: "#{CACHE_PREFIX}:*"
          ).count,
          last_updated_at: metadata["lastUpdatedAt"]
        }
      rescue Redis::BaseError, JSON::ParserError, TypeError => error
        Rails.logger.warn(
          "[SlackChannelCache] cache status failed " \
          "error=#{error.class}: #{error.message}"
        )
        {
          available: false,
          total_channels: nil,
          last_updated_at: nil
        }
      end

      def refresh_until(channel_name)
        target = normalize_name(channel_name)
        return nil if target.blank?

        scan_public_channels(target: target) { |details| write(details) }
      end

      private

      def scan_public_channels(target: nil)
        cursor = nil
        found = nil
        cached_count = 0

        loop do
          response = Service::SlackConnector.with_rate_limit_retry(
            "conversations.list public channel cache"
          ) do
            Service::SlackConnector.client.conversations_list(
              types: "public_channel",
              exclude_archived: true,
              limit: PAGE_SIZE,
              cursor: cursor
            )
          end

          Array(response.channels).each do |channel|
            details = details_for(channel)
            next if details[:name].blank?

            yield(details)
            cached_count += 1
            if target == details[:name] || target == details[:id]
              found ||= details.with_indifferent_access
            end
          end

          break if found.present?

          cursor = response.response_metadata&.next_cursor.to_s
          break if cursor.blank?
        end

        target ? found : cached_count
      rescue => error
        Rails.logger.warn(
          "[SlackChannelCache] Slack refresh failed target=#{target.inspect} " \
          "error=#{Service::SlackConnector.format_api_error(error)}"
        )
        nil
      end

      def details_for(channel)
        {
          id: channel.id.to_s,
          name: normalize_name(channel.name),
          topic: nested_value(channel, :topic),
          purpose: nested_value(channel, :purpose)
        }
      end

      def nested_value(channel, field)
        value = channel.public_send(field) if channel.respond_to?(field)
        return value.value.to_s if value.respond_to?(:value)
        return value[:value].to_s if value.respond_to?(:[]) && value[:value].present?

        value.to_s
      rescue
        ""
      end

      def write(details, key: nil, raise_on_error: false)
        keys = key.present? ? [key] : cache_identifiers(details).map do |identifier|
          cache_key(identifier)
        end
        payload = JSON.generate(details)
        keys.each do |target_key|
          REDIS.set(target_key, payload, ex: CACHE_TTL_SECONDS)
        end
      rescue Redis::BaseError => error
        Rails.logger.warn(
          "[SlackChannelCache] cache write failed name=#{details[:name].inspect} " \
          "error=#{error.class}: #{error.message}"
        )
        raise if raise_on_error
      end

      def write_status(count)
        REDIS.set(
          STATUS_KEY,
          status_payload(count),
          ex: CACHE_TTL_SECONDS
        )
      end

      def promote_staged_cache!(staged_entries, live_keys, count)
        staged_keys = staged_entries.map(&:first)
        destination_keys = staged_entries.map(&:last)
        REDIS.eval(
          PROMOTE_SCRIPT,
          keys: staged_keys + live_keys + [STATUS_KEY],
          argv: [
            staged_keys.length,
            live_keys.length,
            *destination_keys,
            status_payload(count),
            CACHE_TTL_SECONDS
          ]
        )
      end

      def status_payload(count)
        JSON.generate(
          totalChannels: count,
          lastUpdatedAt: Time.current.iso8601
        )
      end

      def cleanup_staging_keys(staged_keys)
        return if staged_keys.blank?

        REDIS.del(*staged_keys)
      rescue Redis::BaseError => error
        Rails.logger.warn(
          "[SlackChannelCache] staging cleanup failed " \
          "error=#{error.class}: #{error.message}"
        )
      end

      def parse_status(raw)
        return {} if raw.blank?

        JSON.parse(raw)
      end

      def cache_entries(channels)
        channels.flat_map do |details|
          cache_identifiers(details).map { |identifier| [identifier, details] }
        end
      end

      def cache_identifiers(details)
        [details[:name], details[:id]].filter_map do |identifier|
          normalized = normalize_name(identifier)
          normalized unless normalized.blank?
        end.uniq
      end

      def live_cache_keys
        [CACHE_PREFIX, CACHE_ID_PREFIX].flat_map do |prefix|
          REDIS.scan_each(match: "#{prefix}:*").to_a
        end
      end

      def cache_key(identifier)
        normalized = normalize_name(identifier)
        prefix = channel_id?(normalized) ? CACHE_ID_PREFIX : CACHE_PREFIX
        "#{prefix}:#{normalized}"
      end
    end
  end
end
