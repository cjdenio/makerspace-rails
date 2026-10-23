class CheckoutMutationLock
  def self.with(member_id:, tool_id:, persistent: false)
    key = "checkout_request_lock/#{member_id}/#{tool_id}"
    token = SecureRandom.uuid
    options = persistent ? { nx: true } : { nx: true, ex: 30 }
    acquired = REDIS.set(key, token, **options)
    raise Error::UnprocessableEntity.new("This checkout is already being processed. Please try again in a moment.") unless acquired
    if persistent
      # Fail closed on lost ownership (for example Redis recovery) before commit.
      yield -> { raise Error::Conflict.new('Checkout catalog lock ownership was lost') unless REDIS.get(key) == token }
    else
      yield
    end
  ensure
    if acquired
      begin
        REDIS.eval("if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
          keys: [key], argv: [token])
      rescue => error
        Rails.logger.warn("[CheckoutLock] release failed: #{error.class}")
      end
    end
  end
end
