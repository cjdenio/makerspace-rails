class CheckoutExpirationNoticeJob < ApplicationJob
  queue_as :default

  def perform
    CheckoutExpirationNotice.run!
    SystemConfig.record_run('checkout_expiration_notice', success: true)
  rescue => error
    SystemConfig.record_run('checkout_expiration_notice', success: false)
    Service::ErrorReporter.notify(error)
    raise
  end
end
