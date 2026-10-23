require "rails_helper"

RSpec.describe ReservationFeeService do
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop, reservable: true, max_reservation_duration_hours: 72) }
  let(:option) { InvoiceOption.create!(name: "Extended use", amount: 10, quantity: 1, resource_class: "fee") }
  let(:day_option) { InvoiceOption.create!(name: "Daily use", amount: 15, quantity: 1, resource_class: "fee") }
  let(:start_at) { (Time.current.in_time_zone(ReservationService::ZONE) + 2.days).beginning_of_day }
  let(:attributes) { { title: "Extended project", shop_id: shop.id, reservation_scope: "shop", tool_ids: [], start_at: start_at, end_at: start_at + 12.hours } }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    shop.update!(duration_fees: [
      { invoice_option_id: option.id.to_s, minimum_hours: 4, maximum_hours: 4, full_day: false },
      { invoice_option_id: day_option.id.to_s, full_day: true }
    ])
  end

  def book(input = attributes)
    quote = ReservationService.preview(member: member, attributes: input)
    ReservationService.create!(member: member, attributes: input.merge(fee_confirmation: quote[:feeConfirmation]))
  end

  it "preserves a legacy shop's fee-free rules through a material edit" do
    legacy = create(:reservation, member: member, shop: shop, reservation_scope: "shop", tool_ids: [],
      start_at: start_at, end_at: start_at + 4.hours, fee_rule_snapshot: [])
    changes = attributes.merge(end_at: start_at + 8.hours)
    preview = ReservationService.preview(member: member, attributes: changes, reservation: legacy)
    expect(preview[:feeTotal]).to eq(0)
    ReservationService.update!(reservation: legacy, attributes: changes)
    expect(legacy.reload.fee_rule_snapshot).to eq([{ "resourceId" => shop.id.to_s, "rules" => [] }])
    expect(legacy.invoice).to be_nil
    expect(Invoice.where(reservation_id: legacy.id.to_s)).to be_empty
  end

  it "keeps retained legacy tools free but snapshots current fees for newly added tools" do
    rule = { invoice_option_id: option.id.to_s, minimum_hours: 4, maximum_hours: 4 }
    retained = create(:tool, shop: shop, reservable: true, max_reservation_duration_hours: 24, duration_fees: [rule])
    added = create(:tool, shop: shop, reservable: true, max_reservation_duration_hours: 24, duration_fees: [rule])
    [retained, added].each { |tool| create(:tool_checkout, member: member, tool: tool) }
    legacy = create(:reservation, member: member, shop: shop, reservation_scope: "tools", tool_ids: [retained.id.to_s],
      start_at: start_at, end_at: start_at + 4.hours, fee_rule_snapshot: [])
    changes = attributes.merge(reservation_scope: "tools", tool_ids: [retained.id.to_s, added.id.to_s], end_at: start_at + 8.hours)
    preview = ReservationService.preview(member: member, attributes: changes, reservation: legacy)
    expect(preview[:feeLines]).to contain_exactly(hash_including(resourceId: added.id.to_s, amount: 20))
    ReservationService.update!(reservation: legacy, attributes: changes.merge(fee_confirmation: preview[:feeConfirmation]))
    expect(legacy.reload.fee_rule_snapshot.find { |entry| entry["resourceId"] == retained.id.to_s }["rules"]).to eq([])
    expect(legacy.fee_invoice.amount).to eq(20)
  end

  it "uses current rules when a legacy reservation moves to a different shop" do
    legacy_shop = create(:shop, reservable: true)
    legacy = create(:reservation, member: member, shop: legacy_shop, reservation_scope: "shop", tool_ids: [],
      start_at: start_at, end_at: start_at + 4.hours, fee_rule_snapshot: [])
    preview = ReservationService.preview(member: member, attributes: attributes, reservation: legacy)
    expect(preview[:feeTotal]).to eq(30)
  end

  it "charges three four-hour units for twelve hours and only the daily fee for a full day" do
    quote = ReservationService.preview(member: member, attributes: attributes)
    expect(quote[:feeTotal]).to eq(30)
    expect(quote[:feeLines].first[:units]).to eq(3)
    daily = ReservationService.preview(member: member, attributes: attributes.merge(full_day: true, end_at: start_at + 1.day))
    expect(daily[:feeTotal]).to eq(15)
    expect(daily[:feeLines].length).to eq(1)
  end

  it "rounds partial billing units up and applies only the longest overlapping rule" do
    shop.update!(duration_fees: shop.duration_fees + [{ invoice_option_id: day_option.id.to_s, minimum_hours: 8, maximum_hours: 8 }])
    quote = ReservationService.preview(member: member, attributes: attributes.merge(end_at: start_at + 12.5.hours))
    expect(quote[:feeLines].length).to eq(1)
    expect(quote[:feeLines].first[:unitHours]).to eq(8)
    expect(quote[:feeTotal]).to eq(30)
  end

  it "requires explicit acceptance of the current price before creating any records" do
    expect { ReservationService.create!(member: member, attributes: attributes) }.to raise_error(Error::UnprocessableEntity, /approve/)
    expect(Reservation.count).to eq(0)
    expect(Invoice.count).to eq(0)
  end

  it "creates an unpaid reservation linked to a fee invoice due four hours before start" do
    reservation = book
    expect(reservation.status).to eq("unpaid")
    expect(reservation.blocking?).to eq(true)
    expect(reservation.fee_invoice).to have_attributes(amount: 30, resource_class: "fee", due_date: start_at - 4.hours)
    expect(reservation.reload.fee_snapshot.first["units"]).to eq(3)
  end

  it "preserves rules and prices on existing reservations after rule and catalog deletion" do
    reservation = book
    shop.update!(duration_fees: [])
    option.destroy
    input = attributes.merge(end_at: start_at + 16.hours)
    quote = ReservationService.preview(member: member, attributes: input, reservation: reservation)
    expect(quote[:feeTotal]).to eq(40)
    expect(reservation.reload.fee_invoice.amount).to eq(30)
    expect(ReservationService.preview(member: member, attributes: attributes)[:feeTotal]).to eq(0)
  end

  it "blocks new charged reservations for overdue fee debt without blocking free reservations" do
    Invoice.create!(member: member, resource_id: member.id.to_s, resource_class: "fee", amount: 5, due_date: 1.hour.ago)
    expect(ReservationService.preview(member: member, attributes: attributes)[:errors]).to include(/overdue/)
    expect(ReservationService.preview(member: member, attributes: attributes.merge(end_at: start_at + 1.hour))[:errors]).not_to include(/overdue/)
  end

  it "requires future midnight boundaries and whole-day resource maximums" do
    shop.update!(reservation_full_day: true)
    expect(ReservationService.preview(member: member, attributes: attributes)[:errors]).to include(/requires full-day/)
    invalid = attributes.merge(full_day: true, start_at: start_at + 1.hour, end_at: start_at + 25.hours)
    expect(ReservationService.preview(member: member, attributes: invalid)[:errors]).to include(/midnight/)
    invalid = attributes.merge(full_day: true, start_at: Time.current.in_time_zone(ReservationService::ZONE).beginning_of_day)
    expect(ReservationService.preview(member: member, attributes: invalid)[:errors]).to include(/future date/)
    shop.max_reservation_duration_hours = 25
    expect(shop).not_to be_valid
  end

  it "counts DST calendar days as one full-day fee and 24 nominal hours" do
    zone = ReservationService::ZONE
    [zone.local(2027, 3, 14), zone.local(2026, 11, 1)].each do |start|
      finish = start.advance(days: 1)
      expect(described_class.duration_hours(start, finish, true)).to eq(24)
      quote = described_class.quote(resources: [shop], start_at: start, end_at: finish, full_day: true)
      expect(described_class.total(quote)).to eq(15)
    end
  end

  it "reconciles the current difference invoice after acquiring the shop lock" do
    reservation = book
    original = reservation.fee_invoice
    original.update!(settled_at: Time.current)
    difference = Invoice.create!(member: member, resource_id: member.id.to_s, resource_class: "fee",
      amount: 10, due_date: start_at - 4.hours, reservation_id: reservation.id.to_s)
    allow(ReservationService).to receive(:with_shop_lock).with(reservation.shop_id) do |&block|
      # Simulate an edit completing while reconciliation waits for the lock.
      Reservation.find(reservation.id).set(invoice: difference.id.to_s, status: "unpaid")
      block.call
    end
    described_class.reconcile!(reservation)
    expect(reservation.reload.invoice).to eq(difference.id.to_s)
    expect(reservation.status).to eq("unpaid")
    expect(difference.reload.settled).to eq(false)
  end

  it "reconciles a reversed historical payment against total fee credit" do
    reservation = book
    original = reservation.fee_invoice
    original.update!(settled_at: Time.current)
    described_class.reconcile!(reservation)
    changes = attributes.merge(end_at: start_at + 16.hours)
    preview = ReservationService.preview(member: member, attributes: changes, reservation: reservation)
    ReservationService.update!(reservation: reservation, attributes: changes.merge(fee_confirmation: preview[:feeConfirmation]))
    difference = reservation.fee_invoice
    expect(difference.amount).to eq(10)
    difference.update!(settled_at: Time.current)
    described_class.reconcile!(reservation)
    expect(reservation.reload.status).to eq("approved")

    original.update!(settled_at: nil)
    expect {
      ReservationInvoiceSyncJob.perform_now(original.id.to_s)
    }.to have_enqueued_job(ReservationFeeNotificationJob).with(reservation.id.to_s)
    expect(reservation.reload.status).to eq("unpaid")
    expect(described_class.amount_due(reservation.fee_snapshot, reservation)).to eq(30)
    expect(Invoice.where(reservation_id: reservation.id.to_s).count).to eq(2)
    original.update!(settled_at: Time.current)
    ReservationInvoiceSyncJob.perform_now(original.id.to_s)
    expect(reservation.reload.status).to eq("approved")
  end

  [0, 10].each do |original_price|
    it "retains a removed tool's original #{original_price} fee when re-added" do
      rule = { invoice_option_id: option.id.to_s, minimum_hours: 4, maximum_hours: 4 }
      retained = create(:tool, shop: shop, reservable: true, max_reservation_duration_hours: 24)
      removed = create(:tool, shop: shop, reservable: true, max_reservation_duration_hours: 24,
        duration_fees: original_price.zero? ? [] : [rule])
      [retained, removed].each { |tool| create(:tool_checkout, member: member, tool: tool) }
      input = attributes.merge(reservation_scope: "tools", tool_ids: [retained.id.to_s, removed.id.to_s], end_at: start_at + 4.hours)
      reservation = book(input)
      removal = input.merge(tool_ids: [retained.id.to_s])
      preview = ReservationService.preview(member: member, attributes: removal, reservation: reservation)
      ReservationService.update!(reservation: reservation, attributes: removal.merge(fee_confirmation: preview[:feeConfirmation]))
      removed.update!(duration_fees: [rule])
      option.update!(amount: 99)
      snapshot = described_class.snapshot(input, reservation.reload)
      lines = described_class.quote(resources: [removed], start_at: start_at, end_at: start_at + 4.hours, full_day: false, rule_snapshot: snapshot)
      expect(described_class.total(lines)).to eq(original_price)
    end
  end

  def reversed_historical_booking
    reservation = book
    original = reservation.fee_invoice
    original.update!(settled_at: Time.current)
    described_class.reconcile!(reservation)
    changes = attributes.merge(end_at: start_at + 16.hours)
    preview = ReservationService.preview(member: member, attributes: changes, reservation: reservation)
    ReservationService.update!(reservation: reservation, attributes: changes.merge(fee_confirmation: preview[:feeConfirmation]))
    reservation.fee_invoice.update!(settled_at: Time.current)
    original.update!(settled_at: nil)
    described_class.reconcile!(reservation)
    reservation
  end

  it "offsets reversed historical debt across edits and new difference invoices" do
    reservation = reversed_historical_booking
    [16, 20, 24].each do |hours|
      changes = attributes.merge(start_at: start_at + 1.day, end_at: start_at + 1.day + hours.hours)
      preview = ReservationService.preview(member: member, attributes: changes, reservation: reservation)
      ReservationService.update!(reservation: reservation, attributes: changes.merge(fee_confirmation: preview[:feeConfirmation]))
      invoices = described_class.linked_invoices(reservation.reload)
      expect(invoices.reject(&:settled).sum(&:amount)).to eq(hours / 4 * 10 - 10)
      expect(invoices.length).to eq(hours == 16 ? 2 : 3)
      expect(reservation.status).to eq("unpaid")
    end
  end

  it "does not duplicate a reversed charge on RM approval" do
    reservation = reversed_historical_booking
    reservation.update!(status: "pending", approval_reasons: ["resource_requires_approval"])
    ReservationService.approve!(reservation: reservation, actor: create(:member, :current))
    invoices = described_class.linked_invoices(reservation.reload)
    expect(invoices.length).to eq(2)
    expect(invoices.reject(&:settled).sum(&:amount)).to eq(30)
    expect(reservation.status).to eq("unpaid")
  end

  it "cleans up a persisted invoice when its creation notification raises, allowing a retry" do
    allow_any_instance_of(Invoice).to receive(:send_rental_email).and_raise("notification unavailable")
    expect { book }.to raise_error("notification unavailable")
    expect(Reservation.count).to eq(0)
    expect(Invoice.count).to eq(0)
    allow_any_instance_of(Invoice).to receive(:send_rental_email).and_call_original
    expect(book.fee_invoice.amount).to eq(30)
    expect(Reservation.count).to eq(1)
    expect(Invoice.count).to eq(1)
  end

  it "cleans up both records when saving the fee snapshot fails, allowing a retry" do
    allow_any_instance_of(Reservation).to receive(:update!).and_raise("snapshot write failed")
    expect { book }.to raise_error("snapshot write failed")
    expect(Reservation.count).to eq(0)
    expect(Invoice.count).to eq(0)
    allow_any_instance_of(Reservation).to receive(:update!).and_call_original
    expect(book.fee_invoice.amount).to eq(30)
    expect(Reservation.count).to eq(1)
    expect(Invoice.count).to eq(1)
  end

  it "restores approval state on payment without reviving a cancelled reservation" do
    reservation = book
    invoice = reservation.fee_invoice
    expect {
      invoice.submit_for_settlement(nil, nil, "reservation-payment")
    }.to have_enqueued_job(ReservationInvoiceSyncJob).with(invoice.id.to_s)
    expect {
      ReservationInvoiceSyncJob.perform_now(invoice.id.to_s)
    }.to have_enqueued_job(ReservationFeeNotificationJob).with(reservation.id.to_s)
    expect(reservation.reload.status).to eq("approved")
    reservation.update!(status: "cancelled")
    described_class.reconcile!(reservation)
    expect(reservation.reload.status).to eq("cancelled")
  end

  it "issues the confirmed fee only after RM approval, then approves on payment" do
    shop.update!(reservation_requires_approval: true)
    reservation = book
    expect(reservation.status).to eq("pending")
    expect(reservation.invoice).to be_nil
    expect(Invoice.where(reservation_id: reservation.id.to_s).count).to eq(0)
    expect(described_class.total(reservation.fee_snapshot)).to eq(30)
    expect(ReservationFeeNotificationJob).not_to have_been_enqueued

    preview = ReservationService.preview(member: member, attributes: attributes, reservation: reservation)
    expect(preview[:feeTotal]).to eq(30)

    ReservationService.approve!(reservation: reservation, actor: create(:member, :current))
    expect(reservation.reload.status).to eq("unpaid")
    expect(reservation.fee_invoice).to have_attributes(amount: 30, due_date: start_at - 4.hours)
    expect(ReservationFeeNotificationJob).to have_been_enqueued.with(reservation.id.to_s)
    reservation.fee_invoice.update!(settled_at: Time.current)
    described_class.reconcile!(reservation)
    expect(reservation.reload.status).to eq("approved")
  end

  it "clears a pending quote when an edit becomes free, so approval creates no invoice" do
    shop.update!(reservation_requires_approval: true)
    reservation = book
    expect(described_class.total(reservation.fee_snapshot)).to eq(30)
    ReservationService.update!(reservation: reservation, attributes: attributes.merge(end_at: start_at + 2.hours))
    expect(reservation.reload.status).to eq("pending")
    expect(reservation.fee_snapshot).to eq([])
    expect(reservation.invoice).to be_nil
    ReservationService.approve!(reservation: reservation, actor: create(:member, :current))
    expect(reservation.reload.status).to eq("approved")
    expect(Invoice.where(reservation_id: reservation.id.to_s)).to be_empty
  end

  [:invoice_callback, :reservation_write].each do |failure|
    it "rolls back a failed difference invoice on #{failure} and allows a clean retry" do
      reservation = book
      original_invoice = reservation.fee_invoice
      original_invoice.update!(settled_at: Time.current)
      described_class.reconcile!(reservation)
      original_end = reservation.end_at
      original_snapshot = reservation.reload.fee_snapshot.deep_dup
      changes = attributes.merge(end_at: start_at + 16.hours)
      preview = ReservationService.preview(member: member, attributes: changes, reservation: reservation)
      changes[:fee_confirmation] = preview[:feeConfirmation]
      if failure == :invoice_callback
        allow_any_instance_of(Invoice).to receive(:send_rental_email).and_raise("difference failed")
      else
        allow(reservation).to receive(:update!).and_wrap_original do |method, *args|
          method.call(*args)
          raise "difference failed"
        end
      end
      expect { ReservationService.update!(reservation: reservation, attributes: changes) }.to raise_error("difference failed")
      expect(reservation.reload.end_at).to eq(original_end)
      expect(reservation.invoice).to eq(original_invoice.id.to_s)
      expect(reservation.previous_invoice_ids).to eq([])
      expect(reservation.fee_snapshot).to eq(original_snapshot)
      expect(reservation.status).to eq("approved")
      expect(Invoice.where(reservation_id: reservation.id.to_s).count).to eq(1)
      expect(original_invoice.reload.settled).to eq(true)
      allow_any_instance_of(Invoice).to receive(:send_rental_email).and_call_original
      allow(reservation).to receive(:update!).and_call_original
      ReservationService.update!(reservation: reservation, attributes: changes)
      expect(reservation.reload.end_at).to eq(start_at + 16.hours)
      expect(reservation.fee_invoice.amount).to eq(10)
      expect(Invoice.where(reservation_id: reservation.id.to_s).count).to eq(2)
    end
  end

  [false, true].each do |write_completed|
    it "restores an unpaid invoice when reservation persistence fails (written: #{write_completed})" do
      reservation = book
      original_invoice = reservation.fee_invoice
      original_fields = original_invoice.attributes.slice("amount", "due_date", "description")
      original_end = reservation.end_at
      original_quote = reservation.reload.fee_snapshot.deep_dup
      changes = attributes.merge(start_at: start_at + 1.day, end_at: start_at + 1.day + 16.hours)
      preview = ReservationService.preview(member: member, attributes: changes, reservation: reservation)
      changes[:fee_confirmation] = preview[:feeConfirmation]
      allow(reservation).to receive(:update!).and_wrap_original do |method, *args|
        method.call(*args) if write_completed
        raise "reservation write failed"
      end
      expect { ReservationService.update!(reservation: reservation, attributes: changes) }.to raise_error("reservation write failed")
      expect(original_invoice.reload.attributes.slice(*original_fields.keys)).to eq(original_fields)
      expect(reservation.reload.end_at).to eq(original_end)
      expect(reservation.fee_snapshot).to eq(original_quote)
      expect(reservation.invoice).to eq(original_invoice.id.to_s)
      allow(reservation).to receive(:update!).and_call_original
      ReservationService.update!(reservation: reservation, attributes: changes)
      expect(original_invoice.reload.amount).to eq(40)
      expect(original_invoice.due_date).to eq(start_at + 1.day - 4.hours)
      expect(reservation.reload.end_at).to eq(start_at + 1.day + 16.hours)
      expect(Invoice.where(reservation_id: reservation.id.to_s).count).to eq(1)
    end
  end

  it "allows a confirmed edit after settlement reversal retains its transaction ID" do
    reservation = book
    invoice = reservation.fee_invoice
    invoice.submit_for_settlement(nil, nil, "completed-transaction")
    invoice.reverse_settlement
    invoice.update!(locked: false, locked_at: nil)
    described_class.reconcile!(reservation)
    expect(invoice.reload.transaction_id).to eq("completed-transaction")
    changes = attributes.merge(end_at: start_at + 16.hours)
    preview = ReservationService.preview(member: member, attributes: changes, reservation: reservation)
    ReservationService.update!(reservation: reservation, attributes: changes.merge(fee_confirmation: preview[:feeConfirmation]))
    expect(reservation.reload.end_at).to eq(start_at + 16.hours)
    expect(invoice.reload.amount).to eq(40)
  end

  it "blocks an actively locked payment but permits an expired claim" do
    reservation = book
    invoice = reservation.fee_invoice
    invoice.update!(locked: true, locked_at: Time.current, transaction_id: "claimed-payment")
    changes = attributes.merge(end_at: start_at + 16.hours)
    preview = ReservationService.preview(member: member, attributes: changes, reservation: reservation)
    changes[:fee_confirmation] = preview[:feeConfirmation]
    expect { ReservationService.update!(reservation: reservation, attributes: changes) }.to raise_error(Error::UnprocessableEntity, /Payment is processing/)
    invoice.update!(locked_at: 16.minutes.ago)
    ReservationService.update!(reservation: reservation, attributes: changes)
    expect(reservation.reload.end_at).to eq(start_at + 16.hours)
  end

  it "updates the pending quote without an invoice and bills that quote on approval" do
    shop.update!(reservation_requires_approval: true)
    reservation = book
    input = attributes.merge(end_at: start_at + 16.hours)
    preview = ReservationService.preview(member: member, attributes: input, reservation: reservation)
    ReservationService.update!(reservation: reservation, attributes: input.merge(fee_confirmation: preview[:feeConfirmation]))
    expect(reservation.reload.status).to eq("pending")
    expect(reservation.invoice).to be_nil
    expect(described_class.total(reservation.fee_snapshot)).to eq(40)
    shop.update!(duration_fees: [])
    option.destroy
    ReservationService.approve!(reservation: reservation, actor: create(:member, :current))
    expect(reservation.fee_invoice.amount).to eq(40)
  end

  it "does not bill denied or cancelled requests awaiting approval" do
    shop.update!(reservation_requires_approval: true)
    denied = book
    actor = create(:member, :current)
    expect {
      ReservationService.deny!(reservation: denied, actor: actor)
    }.to have_enqueued_job(ReservationFeeNotificationJob).with(denied.id.to_s)
    cancelled = book
    ReservationService.cancel!(reservation: cancelled, actor: member)
    expect(Invoice.count).to eq(0)
    expect(denied.reload.invoice).to be_nil
    expect(cancelled.reload.invoice).to be_nil
  end

  it "releases unpaid reservations at start while preserving their invoice debt" do
    reservation = book
    expect {
      travel_to(start_at + 1.minute) { described_class.reconcile!(reservation) }
    }.to have_enqueued_job(ReservationFeeNotificationJob).with(reservation.id.to_s)
    expect(reservation.reload.status).to eq("cancelled")
    expect(reservation.fee_invoice.amount).to eq(30)
    expect(reservation.fee_invoice.settled).to eq(false)
  end
end
