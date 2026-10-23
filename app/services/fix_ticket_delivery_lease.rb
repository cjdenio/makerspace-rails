# Renewable delivery lease. Lost ownership stops the worker before its next
# Slack operation; persisted send intents permit recovery without blind retries.
class FixTicketDeliveryLease
  TTL = 120
  RENEW = "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('EXPIRE', KEYS[1], ARGV[2]) else return 0 end".freeze
  RELEASE = "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) else return 0 end".freeze
  def self.with(ticket_id, check_owner: nil)
    key, token = "fix-ticket-delivery:#{ticket_id}", SecureRandom.uuid
    raise Error::Conflict.new('Delivery already running') unless REDIS.set(key, token, nx: true, ex: TTL)
    owned = true
    check = -> do
      raise Error::Conflict.new('Delivery lease lost') unless owned && REDIS.eval(RENEW, keys: [key], argv: [token, TTL]).to_i == 1
      check_owner&.call
    end
    mutex, wake = Mutex.new, ConditionVariable.new
    stopped = false
    heartbeat = Thread.new do
      loop do
        done = mutex.synchronize { wake.wait(mutex, TTL / 3) unless stopped; stopped }
        break if done
        begin
          check.call
        rescue StandardError
          owned = false
          break
        end
      end
    end
    Thread.current[:fix_delivery_lease] = check
    check.call
    yield
  ensure
    Thread.current[:fix_delivery_lease] = nil
    if heartbeat
      mutex.synchronize { stopped = true; wake.signal }
      heartbeat.join
    end
    REDIS.eval(RELEASE, keys: [key], argv: [token]) if token && owned
  end
end
