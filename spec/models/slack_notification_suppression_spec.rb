require 'rails_helper'

RSpec.describe 'slack notification suppression' do
  it 'sends tool checkout Slack notifications when silence_emails is enabled' do
    member = create(:member, silence_emails: true)
    approver = create(:member)
    shop = Shop.create!(name: "Wood Shop")
    tool = Tool.create!(name: "Table Saw", shop: shop)
    checkout = ToolCheckout.create!(member: member, approved_by: approver, tool: tool)
    SlackUser.create!(member_id: member.id, slack_id: "U_SILENCED")
    allow(::Service::SlackConnector).to receive(:send_slack_message)

    checkout.send_checkout_slack_notification

    expect(::Service::SlackConnector).to have_received(:send_slack_message).with(/Table Saw/, "U_SILENCED")
  end

  it 'sends shop charge Slack notifications when silence_emails is enabled' do
    member = create(:member, silence_emails: true)
    invoice = create(:invoice, member: member, resource_class: "fee", amount: 12.50, name: "Laser fee")
    SlackUser.create!(member_id: member.id, slack_id: "U_SILENCED")
    allow(::Service::SlackConnector).to receive(:send_slack_message)

    invoice.send(:send_shop_charge_slack_notification)

    expect(::Service::SlackConnector).to have_received(:send_slack_message).with(/Laser fee/, "U_SILENCED")
  end

  it 'does not send checkout revocation Slack notifications to revoked members' do
    member = create(:member, status: 'revoked', silence_emails: true)
    shop = Shop.create!(name: "Metal Shop")
    tool = Tool.create!(name: "Welder", shop: shop)
    checkout = ToolCheckout.create!(member: member, tool: tool)
    SlackUser.create!(member_id: member.id, slack_id: "U_REVOKED")
    allow(::Service::SlackConnector).to receive(:send_slack_message)

    checkout.send_revocation_slack_notification

    expect(::Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'does not send shop charge Slack notifications to revoked members' do
    member = create(:member, status: 'revoked', silence_emails: true)
    invoice = create(:invoice, member: member, resource_class: "fee", amount: 12.50, name: "Laser fee")
    SlackUser.create!(member_id: member.id, slack_id: "U_REVOKED")
    allow(::Service::SlackConnector).to receive(:send_slack_message)

    invoice.send(:send_shop_charge_slack_notification)

    expect(::Service::SlackConnector).not_to have_received(:send_slack_message)
  end
end
