require "rails_helper"

RSpec.describe ReservationSlackCanvasMemberAccessJob, type: :job do
  it "synchronizes the member's current access for the affected shops" do
    shop = create(:shop, canvas_today: "FTODAY")
    member = create(
      :member,
      :resource_manager,
      resource_manager_shop_ids: [shop.id.to_s]
    )
    allow(Service::ReservationSlackCanvas).to receive(:sync_member_access!)

    described_class.perform_now(member.id.to_s, [shop.id.to_s])

    expect(Service::ReservationSlackCanvas).to have_received(:sync_member_access!)
      .with(member, shop_ids: [shop.id.to_s])
  end

  it "no-ops when the member no longer exists (Mongoid raise_not_found_error is false)" do
    shop = create(:shop)
    member = create(:member)
    allow(Service::ReservationSlackCanvas).to receive(:sync_member_access!)
    missing_id = member.id.to_s
    member.destroy

    expect { described_class.perform_now(missing_id, [shop.id.to_s]) }.not_to raise_error
    expect(Service::ReservationSlackCanvas).not_to have_received(:sync_member_access!)
  end
end
