# Pure pricing tests can also run without booting Rails or connecting to MongoDB:
# ruby -r rspec/autorun spec/unit/reservation_fee_pricing_spec.rb
require "active_support/all"
require "active_model"
require_relative "../../app/services/reservation_service"
require_relative "../../app/services/reservation_fee_service"

RSpec.describe ReservationFeeService do
  let(:zone) { ReservationService::ZONE }
  let(:start_at) { zone.local(2026, 10, 10) }
  let(:rules) do
    [
      { invoice_option_id: "hourly", minimum_hours: 4, maximum_hours: 4, full_day: false },
      { invoice_option_id: "daily", full_day: true }
    ]
  end
  let(:resource) { double(id: "shop", name: "Shop", duration_fees: rules) }

  before do
    stub_const("InvoiceOption", Class.new) unless defined?(InvoiceOption)
    allow(InvoiceOption).to receive(:where).with(id: "hourly", resource_class: "fee", disabled: false)
      .and_return([double(name: "Four hours", amount: 10)])
    allow(InvoiceOption).to receive(:where).with(id: "daily", resource_class: "fee", disabled: false)
      .and_return([double(name: "Full day", amount: 15)])
  end

  def quote(hours, full_day: false, reservation: nil)
    described_class.quote(resources: [resource], start_at: start_at, end_at: start_at + hours.hours,
      full_day: full_day, reservation: reservation)
  end

  it("does not charge below the threshold") { expect(quote(3.5)).to eq([]) }
  it("charges three units for twelve hours") { expect(described_class.total(quote(12))).to eq(30) }
  it("rounds incomplete units up") { expect(described_class.total(quote(12.5))).to eq(40) }
  it("selects only the daily rule for a full day") { expect(quote(24, full_day: true)).to match([hash_including(amount: 15, units: 1)]) }
  it("does not apply a full-day rule to a timed booking") { expect(described_class.total(quote(24))).to eq(60) }
  it("charges multiple full days") { expect(described_class.total(quote(48, full_day: true))).to eq(30) }

  [24, 48].each do |hourly_duration|
    it "prefers a daily rule over a #{hourly_duration}-hour rule configured first" do
      rules.unshift(invoice_option_id: "hourly", minimum_hours: 24, maximum_hours: hourly_duration)
      expect(quote(48, full_day: true)).to match([hash_including(invoiceOptionId: "daily", amount: 30, units: 2)])
      expect(quote(48)).to match([hash_including(invoiceOptionId: "hourly", unitHours: hourly_duration)])
    end
  end

  it "chooses only the longest overlapping hourly duration" do
    rules << { invoice_option_id: "daily", minimum_hours: 8, maximum_hours: 8 }
    expect(quote(12)).to match([hash_including(amount: 30, units: 2, unitHours: 8)])
  end

  it "prices a saved rule even when the catalog no longer contains it" do
    reservation = double(fee_rule_snapshot: [{ "resourceId" => "shop", "rules" => [
      { "invoice_option_id" => "deleted", "name" => "Original price", "amount" => 7.25, "minimum_hours" => 4, "maximum_hours" => 4 }
    ] }])
    expect(InvoiceOption).not_to receive(:where)
    expect(described_class.total(quote(12, reservation: reservation))).to eq(21.75)
  end

  it "keeps an originally free resource free after a new fee is added" do
    reservation = double(fee_rule_snapshot: [{ "resourceId" => "shop", "rules" => [] }])
    expect(quote(12, reservation: reservation)).to eq([])
  end

  it "quotes retained legacy resources as free even without an explicit snapshot argument" do
    reservation = double(fee_rule_snapshot: [], reservation_scope: "shop", shop_id: "shop")
    expect(InvoiceOption).not_to receive(:where)
    expect(quote(12, reservation: reservation)).to eq([])
  end

  it "uses calendar days rather than elapsed hours on both DST transitions" do
    [zone.local(2027, 3, 14), zone.local(2026, 11, 1)].each do |start|
      finish = start.advance(days: 1)
      expect(described_class.duration_hours(start, finish, true)).to eq(24)
      lines = described_class.quote(resources: [resource], start_at: start, end_at: finish, full_day: true)
      expect(described_class.total(lines)).to eq(15)
    end
  end

  it "adds currency without binary rounding artifacts" do
    expect(described_class.total([{ amount: 0.1 }, { amount: 0.2 }])).to eq(0.3)
  end

  it "saves fees pending approval without touching invoices" do
    stub_const("Invoice", Class.new) unless defined?(Invoice)
    reservation = double(approval_reasons: ["resource_requires_approval"])
    lines = quote(12)
    expect(Invoice).not_to receive(:where)
    expect(Invoice).not_to receive(:create!)
    expect(reservation).to receive(:update!).with(fee_snapshot: lines, status: "pending")
    described_class.apply!(reservation, lines)
  end



end
