require 'rails_helper'

RSpec.describe FixTicketPolicy do
  let(:manager) { build(:member, :admin, :current) }
  let(:reporter) { build(:member, :current) }
  FixTicket::STATUSES.each do |status|
    it "advertises reward nomination accurately for #{status} tickets" do
      ticket = FixTicket.new(_id: 1, reporter_id: reporter.id, status: status)
      expected = FixTicket::ACTIVE.include?(status) || status == 'resolved'
      expect(described_class.new(manager, ticket).capabilities[:canNominateReward]).to eq(expected)
      expect(described_class.new(reporter, ticket).capabilities[:canNominateReward]).to be(false)
      ticket.reward_id = BSON::ObjectId.new
      expect(described_class.new(manager, ticket).capabilities[:canNominateReward]).to be(false)
    end
  end
end
