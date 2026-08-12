class VolunteerSlackCanvasSyncJob < ApplicationJob
  queue_as :default

  def perform(shop_id, struck_task_id = nil)
    shop = Shop.find(shop_id)
    return if shop.nil?

    Service::VolunteerSlackCanvas.sync!(
      shop,
      struck_task_id: struck_task_id
    )
  rescue Mongoid::Errors::DocumentNotFound
    nil
  rescue => error
    message = "[VolunteerSlackCanvasSyncJobError] shop_id=#{shop_id} " \
      "error=#{Service::SlackConnector.format_api_error(error)}"
    $stderr.puts(message)
    Rails.logger.error(message)
    Honeybadger.notify(error) if defined?(Honeybadger)
    raise
  end
end
