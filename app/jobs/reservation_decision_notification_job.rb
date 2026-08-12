class ReservationDecisionNotificationJob < ApplicationJob
  queue_as :default

  def perform(reservation_id)
    reservation = Reservation.find(reservation_id)
    slack_user = SlackUser.find_by(member_id: reservation.member_id)
    return if slack_user.nil? || reservation.member.direct_notifications_suppressed?

    message = "Your reservation *#{reservation.title}* for #{reservation.start_at.in_time_zone(ReservationService::ZONE).strftime("%b %-d, %Y %-I:%M %p")} was *#{reservation.status}*."
    message += "\nNote: #{reservation.decision_note}" if reservation.decision_note.present?
    Service::SlackConnector.send_slack_message(message, slack_user.slack_id)
  rescue => error
    Honeybadger.notify(error) if defined?(Honeybadger)
  end
end
