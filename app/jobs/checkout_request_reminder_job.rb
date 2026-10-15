# Daily scan for checkout requests that have been waiting for approval. Posts the
# "still waiting" reminder for requests open 5, 10 and 15 days (3 in all), declines a
# request that is still unrecorded 5 days after the last one, and retries the
# resolution edit for reminders whose request has since been approved, declined
# or cancelled. Individual failures are reported without stopping the scan.
class CheckoutRequestReminderJob < ApplicationJob
  queue_as :default

  def perform
    now = Time.current
    cutoff = (now.in_time_zone.to_date - CheckoutRequestReminder::INTERVAL_DAYS).end_of_day
    ToolCheckoutRequest.where(status: 'open', :request_date.lte => cutoff).each do |request|
      CheckoutRequestReminder.remind!(request, now: now)
    rescue => error
      Service::ErrorReporter.notify(error, context: { phase: 'checkout request reminder', request_id: request.id.to_s })
    end
    ToolCheckoutRequest.where(status: 'open', reminder_open: true).each do |request|
      CheckoutRequestReminder.time_out_due!(request, now: now)
    rescue => error
      Service::ErrorReporter.notify(error, context: { phase: 'checkout request time out', request_id: request.id.to_s })
    end
    ToolCheckoutRequest.where(:status.ne => 'open', reminder_open: true).each do |request|
      CheckoutRequestReminder.finalize!(request, now: now)
    rescue => error
      Service::ErrorReporter.notify(error, context: { phase: 'checkout request reminder resolution',
                                                      request_id: request.id.to_s })
    end
    SystemConfig.record_run('checkout_request_reminder', success: true)
  rescue => e
    SystemConfig.record_run('checkout_request_reminder', success: false)
    Service::ErrorReporter.notify(e)
    raise
  end
end
