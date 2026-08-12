class CardExpirationCheckJob < ApplicationJob
  queue_as :default

  def perform
    Service::CardExpirationCheck.run!
    SystemConfig.record_run('card_expiration_check', success: true)
  rescue => error
    SystemConfig.record_run('card_expiration_check', success: false)
    Honeybadger.notify('CardExpirationCheckJob failed', context: { error: error.message }) if defined?(Honeybadger)
    raise
  end
end
