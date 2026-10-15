class ReservationFeeNotificationJob < ApplicationJob
  queue_as :default

  def perform(id)
    reservation = Reservation.where(id: id).first
    return unless reservation
    user = SlackUser.find_by(member_id: reservation.member_id)
    return unless user && !reservation.member.direct_notifications_suppressed?

    invoices = ReservationFeeService.linked_invoices(reservation)
    unpaid_invoices = invoices.reject(&:settled)
    fully_paid = unpaid_invoices.empty?
    balance = (fully_paid ? invoices : unpaid_invoices).sum { |invoice| BigDecimal(invoice.amount.to_s) }
    due_date = unpaid_invoices.map(&:due_date).compact.min
    zone = ReservationService::ZONE
    resources = if reservation.reservation_scope == "shop"
      saved_resource = Array(reservation.fee_snapshot).find { |line| line.to_h.stringify_keys["resourceId"] == reservation.shop_id.to_s }
      Shop.where(id: reservation.shop_id).first&.name.presence ||
        saved_resource&.to_h&.stringify_keys&.dig("resourceName").presence || "Deleted shop"
    else
      current_names = reservation.tools.to_h { |tool| [tool.id.to_s, tool.name] }
      saved_names = Array(reservation.fee_snapshot).to_h do |line|
        entry = line.to_h.stringify_keys
        [entry["resourceId"], entry["resourceName"]]
      end
      Array(reservation.tool_ids).map do |tool_id|
        current_names[tool_id.to_s].presence || saved_names[tool_id.to_s].presence || "Deleted tool"
      end.join(", ")
    end
    message = "Reservation: #{reservation.title} — #{resources}\n" \
      "#{reservation.start_at.in_time_zone(zone).strftime('%b %-d, %Y %H:%M %Z')} to #{reservation.end_at.in_time_zone(zone).strftime('%b %-d, %Y %H:%M %Z')}\n" \
      "Status: #{reservation.status}."
    if reservation.status == "unpaid" && reservation.decided_at.present? && reservation.approval_reasons.blank?
      message += " Your reservation has been approved; payment is required to make it valid."
    end
    message += "\nNote: #{reservation.decision_note}" if reservation.decision_note.present?
    if invoices.present?
      message += " #{fully_paid ? 'Paid' : 'Unpaid'}: $#{format('%.2f', balance)}."
      if fully_paid
        message += " Payment confirmed."
        message += " This reservation remains #{reservation.status}; payment does not reinstate it." if reservation.cancelled? || reservation.status == "denied"
      elsif reservation.cancelled?
        message += " Your unpaid reservation has been cancelled. The invoice remains payable."
      elsif reservation.status == "denied"
        message += " Your reservation was denied. The invoice remains payable."
      elsif due_date && due_date < Time.current
        message += " Warning: this is not a valid reservation unless the fee is paid before the reservation starts."
      end
      if unpaid_invoices.length > 1
        message += " The outstanding balance covers #{unpaid_invoices.length} unpaid invoices."
      end
      message += "\nPayment due: #{due_date.in_time_zone(zone).strftime('%b %-d, %Y %H:%M %Z')}." if due_date
      message += " <#{Rails.configuration.x.app_base_url}/billing/invoices|View invoices>"
    end
    if reservation.notified_at.present?
      begin
        Service::SlackConnector.update_slack_message(reservation.notified_channel_id.presence || user.slack_id, reservation.notified_at, message)
        return
      rescue Slack::Web::Api::Errors::SlackError => error
        raise unless %w[message_not_found channel_not_found cant_update_message].include?(error.message)
      end
    end
    response = Service::SlackConnector.send_slack_message(message, user.slack_id)
    reservation.set(notified_at: response["ts"], notified_channel_id: response["channel"]) if response
  end
end
