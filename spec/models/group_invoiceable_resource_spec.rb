require 'rails_helper'

RSpec.describe Group, type: :model do
  describe 'invoiceable resource support' do
    let(:member) { create(:member) }
    let(:group) { create(:group, member: member, groupRep: member.fullname, groupName: member.id.to_s) }

    # See spec/models/member_spec.rb's #send_renewal_slack_message block for
    # why this is needed — Current.request_id is never set in a plain model
    # spec, so without an explicit, unique value per test, the wildcard
    # lookup below would match every key in Redis across the whole suite run.
    around do |example|
      Current.request_id = SecureRandom.uuid
      example.run
      REDIS.keys("#{Current.request_id}.*").each { |key| REDIS.del(key) }
      Current.request_id = nil
    end

    describe '#send_renewal_slack_message' do
      it 'queues both the member DM and management channel notification under distinct keys' do
        slack_user = SlackUser.create!(member_id: member.id, slack_id: "U_TEST_GROUP_MEMBER")

        group.send_renewal_slack_message

        enqueued = Service::SlackConnector.get_enqueued_messages("#{Current.request_id}.*")
        channels = enqueued.values.map { |payload| JSON.parse(payload)["channel"] }

        expect(channels).to include(slack_user.slack_id)
        expect(channels).to include(Service::SlackConnector.members_relations_channel)
        expect(channels.size).to eq(2)
      end

      it 'queues only the management channel notification when the primary member has no SlackUser' do
        group.send_renewal_slack_message

        enqueued = Service::SlackConnector.get_enqueued_messages("#{Current.request_id}.*")
        channels = enqueued.values.map { |payload| JSON.parse(payload)["channel"] }

        expect(channels).to eq([Service::SlackConnector.members_relations_channel])
      end
    end

    describe '#send_renewal_reversal_slack_message' do
      it 'queues both the member DM and management channel notification under distinct keys' do
        slack_user = SlackUser.create!(member_id: member.id, slack_id: "U_TEST_GROUP_MEMBER")

        group.send_renewal_reversal_slack_message

        enqueued = Service::SlackConnector.get_enqueued_messages("#{Current.request_id}.*")
        channels = enqueued.values.map { |payload| JSON.parse(payload)["channel"] }

        expect(channels).to include(slack_user.slack_id)
        expect(channels).to include(Service::SlackConnector.members_relations_channel)
        expect(channels.size).to eq(2)
      end
    end

    it 'stores and removes subscription metadata used by household invoices' do
      group.update!(subscription_id: 'household_subscription', subscription: true)
      expect { group.remove_subscription }.to change { group.reload.subscription_id }.to(nil)
      expect(group.subscription).to be(false)
    end

    it 'returns a truthy value when renewing household expiration' do
      new_expiration = group.expiry + 1.month.to_i * 1000

      expect(group.update_expiration(new_expiration)).to eq(true)
      expect(group.reload.expiry).to eq(new_expiration)
    end

    it 'renews the primary member and card when only secondaries are linked by groupName' do
      secondary = create(:member, groupName: member.id.to_s)
      primary_card = create(:card, member: member)
      secondary_card = create(:card, member: secondary)
      new_expiration = group.expiry + 1.month.to_i * 1000

      member.update!(groupName: nil)
      group.update_expiration(new_expiration)

      expect(member.reload.expirationTime).to eq(new_expiration)
      expect(member.groupName).to eq(member.id.to_s)
      expect(secondary.reload.expirationTime).to eq(new_expiration)
      expect(primary_card.reload.expiry).to eq(new_expiration)
      expect(secondary_card.reload.expiry).to eq(new_expiration)
    end
  end
end
