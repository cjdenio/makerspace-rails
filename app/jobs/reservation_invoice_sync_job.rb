class ReservationInvoiceSyncJob < ApplicationJob
  queue_as :default
  retry_on Error::Conflict, wait: 3.seconds, attempts: 10

  def perform(invoice_id)
    invoice = Invoice.where(id: invoice_id).first
    return unless invoice
    Reservation.any_of({ invoice: invoice_id }, { previous_invoice_ids: invoice_id }, { id: invoice.reservation_id }).each { |reservation| ReservationFeeService.reconcile!(reservation) }
  end
end
