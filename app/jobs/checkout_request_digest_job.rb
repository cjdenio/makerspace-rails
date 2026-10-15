# Daily digest DM to each approver and resource manager listing the open checkout
# requests they can act on. Individual delivery failures are reported without
# stopping the rest of the run.
class CheckoutRequestDigestJob < ApplicationJob
  queue_as :default

  def perform
    CheckoutRequestDigest.deliver_all!
    SystemConfig.record_run('checkout_request_digest', success: true)
  rescue => e
    SystemConfig.record_run('checkout_request_digest', success: false)
    Service::ErrorReporter.notify(e)
    raise
  end
end
