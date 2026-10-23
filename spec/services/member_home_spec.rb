require 'rails_helper'

RSpec.describe MemberHome do
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop, requestor_annotation: 'Ask the shop team') }
  subject(:home) { described_class.new(member) }

  before { allow(REDIS).to receive(:set).and_return(true) }

  describe '#available_checkouts' do
    it 'filters before limiting, puts Orientation first, and inherits requestor annotations' do
      create(:tool, shop: shop, name: 'AAA unavailable', out_of_service: true)
      tools = 12.times.map { |i| create(:tool, shop: shop, name: format('Available %02d', i)) }
      orientation = create(:tool, shop: shop, name: 'oRIENTATION', requestor_annotation: 'Bring ID')
      rows = home.available_checkouts
      expect(rows.map { |row| row[:id] }).to eq([orientation, *tools.first(9)].map { |tool| tool.id.to_s })
      expect(rows.first).to include(name: 'oRIENTATION', shopName: shop.name, requestorAnnotation: 'Bring ID')
      expect(rows.last[:requestorAnnotation]).to eq('Ask the shop team')
    end

    it 'excludes hidden, exempt, unavailable-shop, and already requested or checked-out tools' do
      create(:tool, shop: shop, disabled: true)
      create(:tool, shop: shop, open: true)
      create(:tool, shop: create(:shop, disabled: true))
      create(:tool, shop: create(:shop, out_of_service: true, out_of_service_note: 'Repairs'))
      completed = create(:tool, shop: shop)
      revoked = create(:tool, shop: shop)
      create(:tool_checkout, tool: completed, member: member)
      create(:tool_checkout, tool: revoked, member: member, revoked_at: Time.current)
      requested = create(:tool, shop: shop)
      ToolCheckoutRequest.create!(tool: requested, member: member, status: 'open')
      available = create(:tool, shop: shop)
      expect(home.available_checkouts.pluck(:id)).to eq([available.id.to_s])
    end

    it 'requires every prerequisite to have an active checkout' do
      first = create(:tool, shop: shop)
      second = create(:tool, shop: shop)
      advanced = create(:tool, shop: shop, prerequisite_ids: [first.id.to_s, second.id.to_s])
      create(:tool_checkout, member: member, tool: first)
      revoked = create(:tool_checkout, member: member, tool: second, revoked_at: Time.current)
      expect(home.available_checkouts.pluck(:id)).not_to include(advanced.id.to_s)
      revoked.set(revoked_at: nil)
      expect(home.available_checkouts.pluck(:id)).to include(advanced.id.to_s)
    end

    it 'allows only pending-enabled checkouts for pending members, without needing an expiration' do
      member.set(status: 'pending', expirationTime: nil)
      orientation = create(:tool, shop: shop, name: 'Orientation', allow_pending: true)
      create(:tool, shop: shop)
      expect(home.available_checkouts.pluck(:id)).to eq([orientation.id.to_s])
    end

    %w[nonMember revoked inactive suspended].each do |status|
      it "does not recommend checkouts for #{status} members" do
        member.set(status: status)
        create(:tool, shop: shop, allow_pending: true)
        expect(home.available_checkouts).to be_empty
      end
    end

    it 'does not recommend checkouts for expired active members' do
      member.set(expirationTime: 1.day.ago.to_i * 1000)
      create(:tool, shop: shop)
      expect(home.available_checkouts).to be_empty
    end
  end

  describe '#slack' do
    before do
      member # Factory provisioning is outside the read-only operation under test.
      allow(Service::SlackConnector).to receive(:slack_team_id).and_return('T123')
      allow(Service::SlackConnector).to receive(:new_members_channel).and_return('#new_members')
      expect(Service::SlackConnector).not_to receive(:client)
      expect(Service::MemberProvisioning).not_to receive(:provision)
    end

    def confirm_acceptance
      SlackUser.create!(member: member, slack_id: 'U123', slack_email: member.email)
      member.reload.set(provisioning_email: member.email, slack_joined_at: Time.current, slack_acceptance_pending: false)
    end

    it 'requires a linked Slack ID and confirmed acceptance' do
      expect(home.slack).to eq(accepted: false, newMembersChannelUrl: nil)
      confirm_acceptance
      expect(home.slack).to eq(accepted: true,
        newMembersChannelUrl: 'https://slack.com/app_redirect?team=T123&channel=new_members')
    end

    [true, nil].each do |pending|
      it "keeps the reminder when acceptance pending is #{pending.inspect}" do
        confirm_acceptance
        member.set(slack_acceptance_pending: pending)
        expect(home.slack[:accepted]).to eq(false)
      end
    end

    it 'rejects missing join confirmation and old-email provisioning' do
      confirm_acceptance
      member.set(slack_joined_at: nil)
      expect(home.slack[:accepted]).to eq(false)
      member.set(slack_joined_at: Time.current, provisioning_email: 'old@example.com')
      expect(home.slack[:accepted]).to eq(false)
    end

    it 'rejects an identity belonging to another email or an invalidated identity' do
      confirm_acceptance
      identity = member.slack_user
      SlackUser.collection.find(_id: identity.id).update_one('$set' => { slack_email: 'old@example.com' })
      member.reload
      expect(home.slack[:accepted]).to eq(false)
      SlackUser.collection.find(_id: identity.id).update_one('$set' => { slack_email: member.email, invalidated_at: Time.current })
      member.reload
      expect(home.slack[:accepted]).to eq(false)
    end

    it 'uses a configured channel ID and returns no link when configuration is missing' do
      confirm_acceptance
      allow(Service::SlackConnector).to receive(:new_members_channel).and_return('C123')
      expect(home.slack[:newMembersChannelUrl]).to end_with('channel=C123')
      allow(Service::SlackConnector).to receive(:slack_team_id).and_return(nil)
      expect(home.slack).to eq(accepted: true, newMembersChannelUrl: nil)
      allow(Service::SlackConnector).to receive(:slack_team_id).and_return('T123')
      allow(Service::SlackConnector).to receive(:new_members_channel).and_return('')
      expect(home.slack[:newMembersChannelUrl]).to be_nil
    end
  end
end
