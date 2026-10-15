class ReservationCalendarSyncJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(reservation_id)
    reservation = Reservation.find(reservation_id)
    return if reservation.nil?

    Service::ReservationCalendar.sync!(reservation)
  rescue => error
    Service::GoogleApiErrorReporter.report_if_permission_denied(
      error,
      operation: "reservation_calendar_sync_job",
      resource_type: "Reservation",
      resource_id: reservation_id
    )
    reservation&.set(
      calendar_sync_status: "failed",
      calendar_sync_error: Service::GoogleApiErrorReporter.full_error_message(error).first(2_000)
    )
    Service::ErrorReporter.notify(error)
    raise
  end
end
