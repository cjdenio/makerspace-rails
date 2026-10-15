class CheckoutMutationLock
  def self.with(member_id:, tool_id:)
    key = "checkout_request_lock/#{member_id}/#{tool_id}"
    token = SecureRandom.uuid
    acquired = REDIS.set(key, token, nx: true, ex: 30)
    raise Error::UnprocessableEntity.new("This checkout is already being processed. Please try again in a moment.") unless acquired
    yield
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
