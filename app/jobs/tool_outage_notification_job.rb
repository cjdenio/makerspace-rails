class ToolOutageNotificationJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(tool_id, reservation_ids)
    tool = Tool.find_by(id: tool_id)
    return unless tool

    Reservation.where(:id.in => reservation_ids).each do |reservation|
      notify(reservation) { deliver(tool, reservation) }
    end
  end

  private

  def deliver(tool, reservation)
    member = reservation.member
    return unless member && !member.direct_notifications_suppressed?

    slack_id = member.slack_user&.slack_id
    return if slack_id.blank?

    window = "#{reservation.start_at.strftime('%b %-d, %Y %-I:%M %p')} - " \
      "#{reservation.end_at.strftime('%b %-d, %Y %-I:%M %p')}"
    message = "#{CheckoutDisplay.escape(tool.name)} has been marked out of service. " \
      "Your reservation (#{window}) may be affected; a shop manager will follow up."
    Service::SlackConnector.send_slack_message(message, slack_id)
  end

  def notify(reservation)
    yield
  rescue => error
    Service::ErrorReporter.notify("Tool outage reservation notification failed",
      context: { reservation_id: reservation.id.to_s, error_class: error.class.name })
  end
end
