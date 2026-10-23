class CardExpirationCheckJob < ApplicationJob
  queue_as :default

  def perform
    Service::CardExpirationCheck.run!
    SystemConfig.record_run('card_expiration_check', success: true)
  rescue => error
    SystemConfig.record_run('card_expiration_check', success: false)
    Service::ErrorReporter.notify('CardExpirationCheckJob failed', context: { error: error.message })
    raise
  end
end
