require "rails_helper"

if ENV['RUN_OPTIONAL_SLACK_CHECKOUT_SPECS'] == 'true'
  RSpec.describe SlackCheckoutActiveJob do
    let(:member) { create(:member, :current) }
    let!(:slack_user) { SlackUser.create!(member: member, slack_id: "U123", slack_email: member.email) }
    let(:posted_bodies) { [] }

    before do
      allow(SlackCheckoutOutcomeJob).to receive(:enqueue) do |text, _url, _user|
        posted_bodies << { "text" => text, "response_type" => "ephemeral", "replace_original" => true }
      end
    end

    def perform(text: "active", channel: "woodshop", channel_id: nil)
      described_class.perform_now(
        "response_url" => "https://example.test/response",
        "user_id" => slack_user.slack_id,
        "channel_name" => channel,
        "channel_id" => channel_id,
        "text" => text
      )
    end

    it "scopes checkouts by channel ID when that is the shop's configured Slack channel" do
      channel_shop = create(:shop, name: "Channel Shop", slack_channel: "C12345678")
      other_shop = create(:shop, name: "Other Shop", slack_channel: "other-shop")
      create(:tool_checkout, member: member, tool: create(:tool, shop: channel_shop, name: "Lathe"))
      create(:tool_checkout, member: member, tool: create(:tool, shop: other_shop, name: "Welder"))

      perform(channel: "channel-shop", channel_id: "C12345678")

      expect(posted_bodies.last.fetch("text")).to include("Lathe")
      expect(posted_bodies.last.fetch("text")).not_to include("Welder")
    end

    it "uses the same available-tool content policy as the modal" do
      shop = create(:shop, slack_channel: "woodshop")
      zulu = create(:tool, shop: shop, name: "Zulu", disabled: true)
      alpha = create(:tool, shop: shop, name: "Alpha")
      create(:tool_checkout, member: member, tool: zulu)
      create(:tool_checkout, member: member, tool: alpha)
      CheckoutApprover.create!(member: member, tool_ids: [alpha.id.to_s])

      perform

      text = posted_bodies.last.fetch("text")
      expect(text).to include("Alpha", "Checked out:", "Reservable:")
      expect(text).not_to include("Zulu")
    end

    it "treats a shop resource manager as an approver" do
      shop = create(:shop, slack_channel: "woodshop")
      member.update!(role: "resource_manager", resource_manager_shop_ids: [shop.id.to_s])
      create(:tool_checkout, member: member, tool: create(:tool, shop: shop, name: "Lathe"))

      perform
      expect(posted_bodies.last.fetch("text")).to include("Tool: Lathe", "Checked out:")
    end

    it "lists all checked-out shops alphabetically with names and channels for active all or an unrelated channel" do
      zulu_shop = create(:shop, name: "Zulu Shop", slack_channel: "zulu")
      alpha_shop = create(:shop, name: "Alpha Shop", slack_channel: "alpha")
      create(:tool_checkout, member: member, tool: create(:tool, shop: zulu_shop))
      create(:tool_checkout, member: member, tool: create(:tool, shop: alpha_shop))

      perform(text: "active all")
      text = posted_bodies.last.fetch("text")
      expect(text).to include("Alpha Shop", "Zulu Shop")
      expect(text).to include("Shop:")

      perform(channel: "general")
      expect(posted_bodies.last.fetch("text")).to include("Alpha Shop", "Zulu Shop")
    end

    it "renders a configured channel ID as a Slack channel reference" do
      shop = create(:shop, name: "Private Shop", slack_channel: "C12345678")
      create(:tool_checkout, member: member, tool: create(:tool, shop: shop))

      perform(text: "active all")

      expect(posted_bodies.last.fetch("text")).to include("Shop: Private Shop")
    end
  end
end
