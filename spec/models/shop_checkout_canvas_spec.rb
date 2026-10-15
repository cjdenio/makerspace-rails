require "rails_helper"

if ENV['RUN_OPTIONAL_CHECKOUT_CANVAS_SPECS'] == 'true'
  RSpec.describe Shop, type: :model do
    it "refreshes an existing checkout canvas when its Slack channel changes" do
      shop = create(
        :shop,
        slack_channel: "old-channel",
        checkout_canvas_id: "FCHECKOUTS"
      )

      expect {
        shop.update!(slack_channel: "new-channel")
      }.to have_enqueued_job(ToolCheckoutSlackCanvasSyncJob).with(shop.id.to_s)
    end

    it "creates a canvas when a channel is added to a shop with active checkouts" do
      shop = create(:shop, slack_channel: nil, checkout_canvas_id: nil)
      tool = create(:tool, shop: shop)
      ToolCheckout.create!(member: create(:member, :current), tool: tool)

      expect {
        shop.update!(slack_channel: "new-channel")
      }.to have_enqueued_job(ToolCheckoutSlackCanvasSyncJob).with(shop.id.to_s)
    end
  end
end
