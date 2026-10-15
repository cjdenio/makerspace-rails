require 'rails_helper'

RSpec.describe MemberSummarySerializer do
  before do
    allow(MemberSubscriber).to receive(:send_slack_invite)
  end

  describe '#slack' do
    it 'continues resolving the profile URL by default for other callers' do
      slack_user = instance_double(SlackUser, slack_id: 'U123', real_name: 'Slack Member')
      member = instance_double(Member, slack_user: slack_user)
      expect(Service::SlackConnector).to receive(:slack_user_url).with('U123').and_return('slack://user?team=T123&id=U123')

      expect(described_class.new(member).slack).to eq(
        slack_id: 'U123', name: 'Slack Member', url: 'slack://user?team=T123&id=U123'
      )
    end
  end

  it 'includes provisioning only when the controller grants privileged visibility' do
    member = create(:member)

    privileged = ActiveModelSerializers::SerializableResource.new(
      member,
      serializer: described_class,
      adapter: :attributes,
      include_provisioning: true
    ).as_json
    unprivileged = ActiveModelSerializers::SerializableResource.new(
      member,
      serializer: described_class,
      adapter: :attributes
    ).as_json

    expect(privileged).to have_key(:provisioning)
    expect(privileged.dig(:provisioning, :slack, :status)).to eq('unknown')
    expect(unprivileged).not_to have_key(:provisioning)
  end

  describe '#paid_pending_start' do
    def serialize(member)
      ActiveModelSerializers::SerializableResource.new(
        member,
        serializer: described_class,
        adapter: :attributes
      ).as_json
    end

    it 'is true when a member has a settled membership invoice but no subscription or expiration' do
      member = create(:member, subscription_id: nil, expirationTime: nil)
      create(:settled_invoice, member: member, resource_class: 'member', resource_id: member.id)

      expect(serialize(member)[:paidPendingStart]).to eq(true)
    end

    it 'is false when there is no settled membership invoice' do
      member = create(:member, subscription_id: nil, expirationTime: nil)
      create(:invoice, member: member, resource_class: 'member', resource_id: member.id)

      expect(serialize(member)[:paidPendingStart]).to eq(false)
    end

    it 'is true when a real subscription exists but the member has not started (no expiration)' do
      member = create(:member, subscription_id: 'sub_123', expirationTime: nil)

      expect(serialize(member)[:paidPendingStart]).to eq(true)
    end

    it 'is false once the member has an expiration, even with a settled invoice' do
      member = create(:member, subscription_id: nil, expirationTime: (Time.current + 1.year).to_i * 1000)
      create(:settled_invoice, member: member, resource_class: 'member', resource_id: member.id)

      expect(serialize(member)[:paidPendingStart]).to eq(false)
    end
  end
end
