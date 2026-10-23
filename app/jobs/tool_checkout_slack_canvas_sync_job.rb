class ToolCheckoutSlackCanvasSyncJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(shop_id, checkout_id = nil, action = nil)
    shop = Shop.find(shop_id)
    return if shop.nil?

    checkout = ToolCheckout.where(id: checkout_id).first if checkout_id.present?
    if checkout && action.in?(%w[add remove])
      Service::ToolCheckoutSlackCanvas.sync_checkout!(checkout, action: action)
    else
      Service::ToolCheckoutSlackCanvas.sync!(shop)
    end
  rescue => error
    Service::ToolCheckoutSlackCanvas.report_failure(shop, error) if shop
    message = "[ToolCheckoutSlackCanvasSyncJobError] shop_id=#{shop_id} " \
      "error=#{Service::SlackConnector.format_api_error(error)}"
    $stderr.puts(message)
    Rails.logger.error(message)
    Honeybadger.notify(error) if defined?(Honeybadger)
    raise
  end
end
