class ReservationFeeService
  class << self
    def snapshot(attributes, reservation = nil, resources: nil, read_context: nil)
      resources ||= attributes[:reservation_scope] == "shop" ? Shop.where(id: attributes[:shop_id]).to_a : Tool.where(:id.in => attributes[:tool_ids]).to_a
      read_context ||= ReservationReadContext.new
      saved_rules = resources.to_h { |resource| [resource.id.to_s, saved_resource_rules(resource, reservation)] }
      option_ids = resources.flat_map do |resource|
        next [] if saved_rules[resource.id.to_s]

        Array(resource.duration_fees).map { |raw| raw.to_h.stringify_keys["invoice_option_id"] }
      end
      options = read_context.invoice_options(option_ids)
      history = Array(reservation&.fee_rule_snapshot)
      if reservation
        original_ids = reservation.reservation_scope == "shop" ? [reservation.shop_id] : Array(reservation.tool_ids)
        history += original_ids.map { |id| { "resourceId" => id.to_s, "rules" => [] } }
      end
      selected = resources.map do |resource|
        existing = saved_rules[resource.id.to_s]
        next existing if existing
        rules = Array(resource.duration_fees).map do |raw|
          rule = raw.to_h.stringify_keys
          option = options[rule["invoice_option_id"].to_s]
          rule.merge("name" => option&.name, "amount" => option&.amount)
        end
        { "resourceId" => resource.id.to_s, "rules" => rules }
      end
      (history + selected).uniq { |entry| entry["resourceId"] }
    end

    def saved_resource_rules(resource, reservation)
      return unless reservation

      existing = Array(reservation.fee_rule_snapshot).find { |entry| entry["resourceId"] == resource.id.to_s }
      return existing if existing

      # Legacy bookings have no snapshot entries. Their retained resources were
      # booked fee-free; only newly added resources may adopt current fee rules.
      retained_ids = reservation.reservation_scope == "shop" ? [reservation.shop_id] : Array(reservation.tool_ids)
      return unless retained_ids.map(&:to_s).include?(resource.id.to_s)

      { "resourceId" => resource.id.to_s, "rules" => [] }
    end
    private :saved_resource_rules

    def quote(resources:, start_at:, end_at:, full_day:, reservation: nil, rule_snapshot: nil)
      return [] unless start_at && end_at && end_at > start_at

      hours = duration_hours(start_at, end_at, full_day)
      resources.filter_map do |resource|
        saved = Array(rule_snapshot).find { |entry| entry["resourceId"] == resource.id.to_s } || saved_resource_rules(resource, reservation)
        candidates = Array(saved ? saved["rules"] : resource.duration_fees).map { |rule| rule.to_h.stringify_keys }
        rule = candidates.select do |fee|
          day = ActiveModel::Type::Boolean.new.cast(fee["full_day"])
          day ? full_day : hours >= fee["minimum_hours"].to_f
        end.max_by do |fee|
          day = ActiveModel::Type::Boolean.new.cast(fee["full_day"])
          [day ? 1 : 0, day ? 24 : fee["maximum_hours"].to_f, day ? 24 : fee["minimum_hours"].to_f]
        end
        next unless rule

        option = InvoiceOption.where(id: rule["invoice_option_id"], resource_class: "fee", disabled: false).first unless saved
        price = saved ? rule["amount"] : option&.amount
        name = saved ? rule["name"] : option&.name
        raise Error::UnprocessableEntity.new("A reservation fee is unavailable; please contact a resource manager") unless price.to_f.positive?
        unit_hours = ActiveModel::Type::Boolean.new.cast(rule["full_day"]) ? 24 : rule["maximum_hours"].to_f
        units = (hours / unit_hours).ceil
        { resourceId: resource.id.to_s, resourceName: resource.name, invoiceOptionId: rule["invoice_option_id"].to_s,
          name: name, unitHours: unit_hours, units: units, unitAmount: price,
          amount: (BigDecimal(price.to_s) * units).round(2).to_f }
      end
    end

    def duration_hours(start_at, end_at, full_day)
      return (end_at - start_at) / 1.hour unless full_day
      (end_at.in_time_zone(ReservationService::ZONE).to_date - start_at.in_time_zone(ReservationService::ZONE).to_date).to_i * 24.0
    end

    def total(lines)
      lines.sum { |line| BigDecimal((line[:amount] || line["amount"]).to_s) }.round(2).to_f
    end

    def amount_due(lines, reservation = nil)
      return total(lines) unless reservation
      current = reservation.fee_invoice
      paid = Array(reservation.previous_invoice_ids).filter_map { |id| Invoice.where(id: id).first }.select(&:settled).sum(&:amount)
      paid += current.amount if current&.settled
      amount = [total(lines) - paid, 0].max.round(2)
      amount.zero? && current && !current.settled ? current.amount : amount
    end

    def confirmation(lines, reservation = nil)
      Digest::SHA256.hexdigest({ lines: lines, amount: amount_due(lines, reservation) }.to_json)
    end

    def overdue_fees?(member)
      Invoice.where(member_id: member.id, resource_class: "fee", settled_at: nil).any? do |invoice|
        invoice.due_date && invoice.due_date < Time.current
      end
    end

    def confirm!(lines, attributes, reservation = nil)
      invoice = reservation&.fee_invoice
      if invoice && !invoice.settled && (invoice.locked && invoice.locked_at && invoice.locked_at >= 15.minutes.ago)
        raise Error::UnprocessableEntity.new("Payment is processing. Please wait before changing this reservation")
      end
      return if amount_due(lines, reservation).zero?
      token = confirmation(lines, reservation)
      unless attributes.to_h.symbolize_keys[:fee_confirmation] == token
        raise Error::UnprocessableEntity.new("Please review and approve the reservation fee of $#{format('%.2f', amount_due(lines, reservation))}. Use the member portal to confirm the fee")
      end
    end

    def apply!(reservation, lines, approved: false)
      lines = Array(lines).map { |line| line.to_h.symbolize_keys }
      if reservation.approval_reasons.present? && !approved
        reservation.update!(fee_snapshot: lines, status: "pending")
        return
      end
      current = reservation.fee_invoice || Invoice.where(reservation_id: reservation.id.to_s).order_by(created_at: :desc).first
      reservation.set(invoice: current.id.to_s) if current && reservation.invoice.blank?
      historical = Array(reservation.previous_invoice_ids).map(&:to_s).uniq
        .reject { |id| id == current&.id.to_s }
        .filter_map { |id| Invoice.where(id: id).first }
      paid = historical.select(&:settled).sum(&:amount)
      paid += current.amount if current&.settled
      # Reversed historical invoices remain payable. Offset that debt before
      # updating or creating a difference invoice, rather than billing it twice.
      historical_unpaid = historical.reject(&:settled).sum(&:amount)
      amount = [total(lines) - paid - historical_unpaid, 0].max.round(2)
      details = lines.map { |line| "#{line[:resourceName]}: #{line[:units]} × #{line[:name]} ($#{format('%.2f', line[:unitAmount])})" }.join("; ")
      if current && !current.settled
        original = Reservation.find(reservation.id).attributes
        changed_fields = reservation.changes.keys | %w[fee_snapshot status updated_at]
        original_invoice_fields = current.attributes.slice("amount", "due_date", "description")
        begin
          if amount.positive?
            current.update!(amount: amount, due_date: reservation.start_at - 4.hours, description: details)
          end
          # An accepted unpaid charge survives even when an edit becomes free.
          reservation.update!(fee_snapshot: lines, status: "unpaid")
        rescue
          current.set(original_invoice_fields)
          restore_reservation_fields!(reservation, original, changed_fields)
          raise
        end
        return
      elsif amount.positive?
        history = Array(reservation.previous_invoice_ids)
        history |= [current.id.to_s] if current
        # Keep the new invoice's ID even when an after_create callback raises.
        invoice = Invoice.new(member: reservation.member, resource_class: "fee", resource_id: reservation.member_id.to_s,
          name: "Reservation: #{reservation.title}", description: details, amount: amount, quantity: 1,
          due_date: reservation.start_at - 4.hours, reservation_id: reservation.id.to_s)
        original = Reservation.find(reservation.id).attributes
        changed_fields = reservation.changes.keys | %w[invoice previous_invoice_ids fee_snapshot status updated_at]
        begin
          invoice.save!
          reservation.assign_attributes(invoice: invoice.id.to_s, previous_invoice_ids: history)
          reservation.update!(fee_snapshot: lines, status: "unpaid")
        rescue
          # Restore only fields this operation writes; preserve concurrent DM metadata.
          restore_reservation_fields!(reservation, original, changed_fields)
          invoice.delete
          reservation.reload
          raise
        end
        return

      end
      reservation.update!(fee_snapshot: lines, status: (amount.positive? || historical_unpaid.positive?) ? "unpaid" : (reservation.approval_reasons.present? ? "pending" : "approved"))
    end

    def restore_reservation_fields!(reservation, original, changed_fields)
      reservation.set(original.slice(*changed_fields))
      missing_fields = changed_fields - original.keys
      reservation.unset(*missing_fields) if missing_fields.present?
      reservation.reload
    end
    private :restore_reservation_fields!

    def linked_invoices(reservation)
      ids = ([reservation.invoice] + Array(reservation.previous_invoice_ids)).compact.map(&:to_s).uniq
      Invoice.where(:id.in => ids).to_a
    end

    def reconcile!(reservation)
      changed = false
      ReservationService.send(:with_shop_lock, reservation.shop_id) do
        reservation.reload
        invoice = reservation.fee_invoice || Invoice.where(reservation_id: reservation.id.to_s).order_by(created_at: :desc).first
        return unless invoice
        reservation.set(invoice: invoice.id.to_s) if reservation.invoice.blank?
        invoices = linked_invoices(reservation)
        paid_credit = invoices.select(&:settled).sum { |item| BigDecimal(item.amount.to_s) }
        fully_paid = invoice.settled && paid_credit >= BigDecimal(total(reservation.fee_snapshot).to_s)
        overdue = invoices.reject(&:settled).any? { |item| item.due_date && item.due_date < Time.current }
        if reservation.blocking? && !fully_paid && reservation.status != "unpaid"
          reservation.update!(status: "unpaid")
          changed = true
          ReservationService.send(:enqueue_external_syncs, reservation)
        end
        if reservation.status == "unpaid"
          if fully_paid
            # Payment after the start cannot reclaim capacity already released.
            status = invoices.select(&:settled).map(&:settled_at).max >= reservation.start_at ? "cancelled" : (reservation.approval_reasons.present? ? "pending" : "approved")
            reservation.update!(status: status)
            changed = true
            ReservationService.send(:enqueue_external_syncs, reservation)
          elsif overdue && reservation.start_at <= Time.current
            reservation.update!(status: "cancelled", decision_note: "Unpaid reservation cancelled at start time")
            changed = true
            ReservationService.send(:enqueue_external_syncs, reservation)
          end
        end
      end
      ReservationFeeNotificationJob.perform_later(reservation.id.to_s) unless changed
    end
  end
end
