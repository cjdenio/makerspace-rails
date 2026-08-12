class ReservationSlackReminderSyncJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(reservation_id)
    reservation = Reservation.find(reservation_id)
    Service::ReservationSlackReminder.sync!(reservation)
  rescue Mongoid::Errors::DocumentNotFound
    nil
  rescue => error
    message = "[ReservationSlackReminderError] reservation_id=#{reservation_id} " \
      "error=#{Service::SlackConnector.format_api_error(error)}"
    $stderr.puts(message)
    Rails.logger.error(message)
    Honeybadger.notify(error) if defined?(Honeybadger)
    raise
  end
end
