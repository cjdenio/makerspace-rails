class ReservationSlackCanvasSyncJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(shop_id, dates)
    shop = Shop.find(shop_id)
    return if shop.nil?

    Service::ReservationSlackCanvas.sync!(shop, dates: dates)
  rescue => error
    Rails.logger.error(
      "[ReservationSlackCanvasError] shop_id=#{shop_id} " \
      "slack_channel=#{shop&.slack_channel.inspect} " \
      "dates=#{Array(dates).join(',')} " \
      "error=#{Service::SlackConnector.format_api_error(error)}"
    )
    Honeybadger.notify(error) if defined?(Honeybadger)
    raise
  end
end
