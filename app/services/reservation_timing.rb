# Only fixed operation labels and aggregate metrics are logged. In particular,
# never log Slack payloads, response URLs, reservation titles or member details.
module ReservationTiming
  def self.measure(operation)
    metrics = { resource_count: 0, outcome: "success" }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield metrics
  rescue StandardError
    metrics[:outcome] = "error"
    raise
  ensure
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    Rails.logger.info({ event: "reservation_timing", operation: operation,
      resource_count: metrics[:resource_count], outcome: metrics[:outcome],
      elapsed_ms: elapsed.round(2) }.to_json)
  end
end
