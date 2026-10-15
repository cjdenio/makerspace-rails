require "rails_helper"

if ENV['RUN_OPTIONAL_CHECKOUT_CANVAS_SPECS'] == 'true'
  RSpec.describe Tool, type: :model do
    let(:shop) { create(:shop, checkout_canvas_id: "FCHECKOUTS") }

    it "refreshes an existing checkout canvas when a tool becomes hidden" do
      tool = create(:tool, shop: shop)

      expect {
        tool.update!(disabled: true)
      }.to have_enqueued_job(ToolCheckoutSlackCanvasSyncJob).with(shop.id.to_s)
    end

    it "refreshes an existing checkout canvas when a tool is deleted" do
      tool = create(:tool, shop: shop)

      expect {
        tool.destroy!
      }.to have_enqueued_job(ToolCheckoutSlackCanvasSyncJob).with(shop.id.to_s)
    end

    it "does not create a checkout canvas solely because a tool is edited" do
      shop.update!(checkout_canvas_id: nil)
      tool = create(:tool, shop: shop)

      expect {
        tool.update!(description: "Updated")
      }.not_to have_enqueued_job(ToolCheckoutSlackCanvasSyncJob)
    end

    it "creates the destination canvas when a checked-out tool moves shops" do
      destination = create(:shop)
      tool = create(:tool, shop: shop)
      ToolCheckout.create!(member: create(:member, :current), tool: tool)

      expect {
        tool.update!(shop: destination)
      }.to have_enqueued_job(ToolCheckoutSlackCanvasSyncJob)
        .with(destination.id.to_s)
    end
  end
end
