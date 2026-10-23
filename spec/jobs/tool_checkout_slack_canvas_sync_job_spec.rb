require "rails_helper"

RSpec.describe ToolCheckoutSlackCanvasSyncJob do
  it "dispatches a single-checkout canvas edit" do
    shop = create(:shop)
    checkout = create(:tool_checkout, tool: create(:tool, shop: shop))
    allow(Service::ToolCheckoutSlackCanvas).to receive(:sync_checkout!)

    described_class.new.perform(shop.id.to_s, checkout.id.to_s, "add")

    expect(Service::ToolCheckoutSlackCanvas).to have_received(:sync_checkout!)
      .with(checkout, action: "add")
  end

  it "no-ops when the shop no longer exists (Mongoid raise_not_found_error is false)" do
    shop = create(:shop)
    allow(Service::ToolCheckoutSlackCanvas).to receive(:sync!)
    missing_id = shop.id.to_s
    shop.destroy

    expect { described_class.new.perform(missing_id) }.not_to raise_error
    expect(Service::ToolCheckoutSlackCanvas).not_to have_received(:sync!)
  end
end
