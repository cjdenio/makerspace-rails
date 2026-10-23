class ReservationSlackCanvasMemberAccessJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(member_id, shop_ids)
    member = Member.find(member_id)
    return if member.nil?

    Service::ReservationSlackCanvas.sync_member_access!(
      member,
      shop_ids: shop_ids
    )
  rescue => error
    Rails.logger.error(
      "[ReservationSlackCanvasMemberAccessError] member_id=#{member_id} " \
      "shop_ids=#{Array(shop_ids).join(',')} " \
      "error=#{Service::SlackConnector.format_api_error(error)}"
    )
    Honeybadger.notify(error) if defined?(Honeybadger)
    raise
  end
end
