require 'rails_helper'

RSpec.describe Shop do
  it 'destroys active and archived groups before their included and prerequisite tools' do
    shop = create(:shop)
    unrelated = create(:tool, shop: shop)
    included = create(:tool, shop: shop)
    prerequisite = create(:tool, shop: shop)
    groups = [false, true].map do |archived|
      ToolGroup.create!(shop: shop, name: "Kit #{archived}", archived: archived,
        included_tool_ids: [included.id.to_s], prerequisite_ids: [prerequisite.id.to_s])
    end
    other_shop = create(:shop)
    other_tool = create(:tool, shop: other_shop)
    survivor = ToolGroup.create!(shop: other_shop, name: 'Other kit', included_tool_ids: [other_tool.id.to_s])

    expect { included.destroy }.to raise_error(Error::Conflict)
    expect { shop.destroy }.not_to raise_error
    expect(Shop.where(id: shop.id)).not_to exist
    expect(Tool.where(:id.in => [unrelated.id, included.id, prerequisite.id])).not_to exist
    expect(ToolGroup.where(:id.in => groups.map(&:id))).not_to exist
    expect(survivor.reload).to be_persisted
    expect(other_tool.reload).to be_persisted
  end

  it 'retires only open requests for destroyed groups and preserves request history' do
    shop = create(:shop)
    included = create(:tool, shop: shop)
    member = create(:member, :current)
    ToolCheckout.create!(member: member, tool: included, defer_users_channel_invitation: true, defer_group_callbacks: true)
    groups = [false, true].map do |archived|
      ToolGroup.create!(shop: shop, name: "Kit #{archived}", archived: archived, included_tool_ids: [included.id.to_s])
    end
    checkout_requests = groups.map { |group| ToolCheckoutRequest.create!(member: member, tool_group: group) }
    closed_checkout = ToolCheckoutRequest.create!(member: member, tool_group: groups.first, status: 'closed')
    approved_volunteer = CheckoutApproverRequest.create!(member: member, tool_group: groups.first, status: 'approved')
    volunteer_requests = groups.map { |group| CheckoutApproverRequest.create!(member: member, tool_group: group) }
    other_tool = create(:tool)
    other_group = ToolGroup.create!(shop: other_tool.shop, name: 'Other kit', included_tool_ids: [other_tool.id.to_s])
    ToolCheckout.create!(member: member, tool: other_tool, defer_users_channel_invitation: true, defer_group_callbacks: true)
    other_checkout = ToolCheckoutRequest.create!(member: member, tool_group: other_group)
    other_volunteer = CheckoutApproverRequest.create!(member: member, tool_group: other_group)

    shop.destroy!

    expect(checkout_requests.map { |request| request.reload.status }).to eq(%w[deleted deleted])
    expect(volunteer_requests.map { |request| request.reload.status }).to eq(%w[revoked revoked])
    expect(closed_checkout.reload.status).to eq('closed')
    expect(approved_volunteer.reload.status).to eq('approved')
    expect(other_checkout.reload.status).to eq('open')
    expect(other_volunteer.reload.status).to eq('open')
    expect(ToolGroup.where(:id.in => groups.map(&:id))).not_to exist
  end

  [false, true].each do |slack_failure|
    it "retires announced requests after cascading deletion#{slack_failure ? ' even if one Slack update fails' : ''}" do
      shop = create(:shop, slack_channel: 'C11111111')
      tool = create(:tool, shop: shop)
      member = create(:member, :current)
      groups = [nil, 'C22222222'].map.with_index do |channel, index|
        ToolGroup.create!(shop: shop, name: "Deleted kit #{index}", included_tool_ids: [tool.id.to_s],
          announce: true, announce_channel: channel)
      end
      requests = groups.map.with_index do |group, index|
        ToolCheckoutRequest.create!(member: member, tool_group: group, message_id: "request-#{index}")
      end
      historical = ToolCheckoutRequest.create!(member: member, tool_group: groups.first,
        status: 'closed', message_id: 'history-ts')
      allow(Service::ErrorReporter).to receive(:notify)
      allow(Service::SlackConnector).to receive(:update_slack_message) do |_channel, timestamp, _message|
        request = ToolCheckoutRequest.find_by(message_id: timestamp)
        expect(request.status).to eq('deleted')
        expect(request.target).to be_nil
        raise 'Slack unavailable' if slack_failure && timestamp == 'request-0'
      end

      expect { shop.destroy! }.not_to raise_error

      expect(Shop.where(id: shop.id)).not_to exist
      expect(requests.map { |row| row.reload.status }).to eq(%w[deleted deleted])
      expect(historical.reload.status).to eq('closed')
      expect(Service::SlackConnector).to have_received(:update_slack_message).with('C11111111', 'request-0',
        include('cancelled their checkout request for *Deleted kit 0*'))
      expect(Service::SlackConnector).to have_received(:update_slack_message).with('C22222222', 'request-1',
        include('cancelled their checkout request for *Deleted kit 1*'))
      expect(Service::SlackConnector).not_to have_received(:update_slack_message).with(anything, 'history-ts', anything)
      expect(Service::ErrorReporter).to have_received(:notify).with(instance_of(RuntimeError)) if slack_failure
    end
  end

  it 'keeps a request announcement intact if resolution wins after deletion captures open posts' do
    shop = create(:shop, slack_channel: 'C11111111')
    tool = create(:tool, shop: shop)
    group = ToolGroup.create!(shop: shop, name: 'Kit', included_tool_ids: [tool.id.to_s])
    member = create(:member, :current)
    checkout = ToolCheckout.create!(member: member, tool: tool,
      defer_users_channel_invitation: true, defer_group_callbacks: true)
    request = ToolCheckoutRequest.create!(member: member, tool_group: group, message_id: 'resolved-ts')
    allow_any_instance_of(ToolGroup).to receive(:close_open_requests!).and_wrap_original do |cleanup|
      # Resolution finishes after the callback captures the announcement but
      # before its conditional open-request update.
      request.update!(status: 'closed', checked_out_id: checkout.id)
      cleanup.call
    end
    allow(Service::SlackConnector).to receive(:update_slack_message)

    shop.destroy!

    expect(request.reload.status).to eq('closed')
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end
end
