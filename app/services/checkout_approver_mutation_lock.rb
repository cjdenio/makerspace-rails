# Serializes updates to a member's single CheckoutApprover record even when
# separate tool requests are decided concurrently.
class CheckoutApproverMutationLock
  def self.with(member_id:)
    key = "checkout_approver_lock/#{member_id}"
    token = SecureRandom.uuid
    acquired = REDIS.set(key, token, nx: true, ex: 30)
    raise Error::UnprocessableEntity.new("This approver record is already being updated. Please try again in a moment.") unless acquired
    yield
  ensure
    if acquired
      begin
        REDIS.eval("if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
          keys: [key], argv: [token])
      rescue => error
        Rails.logger.warn("[CheckoutApproverLock] release failed: #{error.class}")
      end
    end
  end
end
