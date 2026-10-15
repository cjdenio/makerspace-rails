require "rails_helper"

RSpec.describe "Fresh reservation evaluations" do
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:start_at) { (Time.current.in_time_zone(ReservationService::ZONE) + 2.days).change(hour: 10, min: 0, sec: 0) }
  let(:attributes) do
    { title: "Fresh evaluation", shop_id: shop.id.to_s, reservation_scope: "tools",
      tool_ids: [tool.id.to_s], start_at: start_at, end_at: start_at + 1.hour }
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    checkout = ToolCheckout.new(member: member, tool: tool)
    ToolCheckout.collection.insert_one(checkout.attributes)
  end

  it "observes a checkout revoked while creation waits for the lock" do
    expect(ReservationService.preview(member: member, attributes: attributes)[:eligible]).to eq(true)
    allow(ReservationService).to receive(:with_shop_locks) do |_, &block|
      ToolCheckout.where(member_id: member.id).update_all(revoked_at: Time.current)
      block.call
    end
    expect { ReservationService.create!(member: member, attributes: attributes) }
      .to raise_error(Error::UnprocessableEntity, /Missing required checkout/)
    expect(Reservation.count).to eq(0)
  end

  it "rejects a fee confirmation when the price changes before lock acquisition" do
    option = InvoiceOption.create!(name: "Fee", amount: 10, quantity: 1, resource_class: "fee")
    tool.set(duration_fees: [{ "invoice_option_id" => option.id.to_s, "minimum_hours" => 0.5, "maximum_hours" => 1 }])
    preview = ReservationService.preview(member: member, attributes: attributes)
    expect(preview[:feeTotal]).to eq(10)
    allow(ReservationService).to receive(:with_shop_locks) do |_, &block|
      option.set(amount: 20)
      block.call
    end
    expect do
      ReservationService.create!(member: member, attributes: attributes.merge(fee_confirmation: preview[:feeConfirmation]))
    end.to raise_error(Error::UnprocessableEntity, /review and approve.*20\.00/)
    expect(Reservation.count).to eq(0)
  end

  it "continues reporting invalid cross-shop selections without quoting their fees" do
    foreign = create(:tool, shop: create(:shop))
    preview = ReservationService.preview(member: member, attributes: attributes.merge(tool_ids: [foreign.id.to_s]))
    expect(preview[:eligible]).to eq(false)
    expect(preview[:errors]).to include("One or more selected tools are invalid")
    expect(preview[:feeLines]).to eq([])
  end

  it "uses fresh catalog rules for a subsequent preview" do
    expect(ReservationService.preview(member: member, attributes: attributes)[:eligible]).to eq(true)
    tool.set(disabled: true)
    expect(ReservationService.preview(member: member, attributes: attributes)[:errors])
      .to include("One or more selected tools are not reservable")
  end
end
