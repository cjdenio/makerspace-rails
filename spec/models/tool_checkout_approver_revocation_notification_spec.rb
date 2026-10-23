require "rails_helper"

RSpec.describe ToolCheckout, "original approver revocation notification" do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:member) { create(:member, :current) }
  let(:approver) { create(:member, :current) }
  let(:revoker) { create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s]) }
  let(:checkout) { create(:tool_checkout, member: member, tool: tool, approved_by: approver, checked_out_at: Time.utc(2026, 9, 1)) }

  before do
    CheckoutApprover.create!(member: approver, tool_ids: [tool.id.to_s])
    SlackUser.create!(member: approver, slack_id: "UAPPROVER", slack_email: approver.email)
    SlackUser.create!(member: member, slack_id: "UMEMBER", slack_email: member.email)
    allow(Service::SlackConnector).to receive(:send_slack_message)
  end

  it "DMs a different still-authorized original approver without exposing an ordinary revoker's name" do
    checkout.send_approver_revocation_slack_notification(revoker)

    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      a_string_including(shop.name, tool.name, "2026-09-01", "<@UMEMBER>", "an RM"),
      "UAPPROVER"
    )
    expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(a_string_including(revoker.fullname), anything)
  end

  it "does not DM an original approver whose authorization was removed" do
    CheckoutApprover.where(member_id: approver.id).delete_all
    checkout.send_approver_revocation_slack_notification(revoker)
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it "includes the revoker name when the original approver is an admin" do
    approver.update!(role: "admin")
    checkout.send_approver_revocation_slack_notification(revoker)
    expect(Service::SlackConnector).to have_received(:send_slack_message)
      .with(a_string_including("an RM (#{revoker.fullname})"), "UAPPROVER")
  end
end
