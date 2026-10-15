require "rails_helper"

RSpec.describe "Reservation fee read reuse" do
  include ReservationReadMeasurement

  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop) }
  let(:option) { InvoiceOption.create!(name: "Shared fee", amount: 10, quantity: 1, resource_class: "fee") }
  let(:rule) { { "invoice_option_id" => option.id.to_s, "minimum_hours" => 0.5, "maximum_hours" => 1 } }

  [1, 25, 100].each do |count|
    it "uses one fee-option read and no resource reload for #{count} resources" do
      tools = Array.new(count) { |index| Tool.new(shop: shop, name: "Tool #{index}", duration_fees: [rule, rule.dup]) }
      attributes = { reservation_scope: "tools", shop_id: shop.id, tool_ids: tools.map(&:id) }
      snapshot = nil
      measured = measure_reservation_reads do
        snapshot = ReservationFeeService.snapshot(attributes, resources: tools)
      end
      expect(measured[:commands]).to eq([["find", "invoice_options"]])
      expect(snapshot.size).to eq(count)
      expect(snapshot.first["rules"].map { |fee| fee["amount"] }).to eq([10, 10])
      start_at = 2.days.from_now
      quote = ReservationFeeService.quote(resources: tools, start_at: start_at,
        end_at: start_at + 1.hour, full_day: false, rule_snapshot: snapshot)
      expect(ReservationFeeService.total(quote)).to eq(count * 10)
    end
  end

  it "retains saved and legacy rules without loading current options" do
    retained = Tool.new(shop: shop, name: "Retained", duration_fees: [rule])
    saved = { "resourceId" => retained.id.to_s, "rules" => [rule.merge("name" => "Old fee", "amount" => 3)] }
    reservation = Reservation.new(shop: shop, member: member, reservation_scope: "tools",
      tool_ids: [retained.id.to_s], fee_rule_snapshot: [saved])
    attributes = { reservation_scope: "tools", tool_ids: [retained.id] }
    measured = measure_reservation_reads do
      expect(ReservationFeeService.snapshot(attributes, reservation, resources: [retained])).to eq([saved])
      reservation.fee_rule_snapshot = []
      expect(ReservationFeeService.snapshot(attributes, reservation, resources: [retained]))
        .to eq([{ "resourceId" => retained.id.to_s, "rules" => [] }])
    end
    expect(measured[:commands]).to be_empty
  end

  it "preserves disabled option errors and reloads prices in a new evaluation" do
    tool = Tool.new(shop: shop, name: "Tool", duration_fees: [rule])
    attributes = { reservation_scope: "tools", tool_ids: [tool.id] }
    first = ReservationFeeService.snapshot(attributes, resources: [tool])
    option.set(amount: 20)
    second = ReservationFeeService.snapshot(attributes, resources: [tool])
    expect(first.first["rules"].first["amount"]).to eq(10)
    expect(second.first["rules"].first["amount"]).to eq(20)
    option.set(disabled: true)
    third = ReservationFeeService.snapshot(attributes, resources: [tool])
    expect(third.first["rules"].first["amount"]).to be_nil
    start_at = 2.days.from_now
    expect do
      ReservationFeeService.quote(resources: [tool], start_at: start_at, end_at: start_at + 1.hour,
        full_day: false, rule_snapshot: third)
    end.to raise_error(Error::UnprocessableEntity, /fee is unavailable/)
  end
end
