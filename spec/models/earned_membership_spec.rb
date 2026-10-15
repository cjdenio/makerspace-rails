require 'rails_helper'

#https://github.com/mongoid/mongoid-rspec

RSpec.describe EarnedMembership, type: :model do
  describe "public methods" do
    let!(:member) { create(:member, expirationTime: (Time.now + 2.months).to_i * 1000)}
    let(:outstanding_term) { build(:term) }
    let(:other_term) { build(:term) }
    let(:completed_term) { build(:term, satisfied: true) }
    let(:outstanding_requirement) { build(:requirement, terms: [outstanding_term], term_length: 1) }
    let(:completed_requirement) { build(:requirement, terms: [completed_term], term_length: 1) }
    let(:future_requirement) { build(:requirement, terms: [other_term], term_length: 5) }

    before(:each) do
      EarnedMembership::Requirement.skip_callback(:create, :before, :build_first_term)
    end
    after(:each) do
      EarnedMembership::Requirement.set_callback(:create, :before, :build_first_term)
    end
    it "fetches outstanding requirements for membership" do
      membership = create(:earned_membership_no_requirements,
        requirements: [outstanding_requirement, completed_requirement, future_requirement],
        member: member)
      expect(membership.outstanding_requirements).to eq([outstanding_requirement])
    end

    it "dispatches renew member if no outstanding requirements" do
        membership = create(:earned_membership_no_requirements,
          requirements: [completed_requirement, future_requirement],
          member: member)
        expect(membership).to receive(:renew_member)
        membership.evaluate_for_renewal

        other_member = create(:member, expirationTime: (Time.now + 2.months).to_i * 1000)
        other_membership = create(:earned_membership_no_requirements,
          requirements: [outstanding_requirement, completed_requirement, future_requirement],
          member: other_member)
        expect(other_membership).not_to receive(:renew_member)
        other_membership.evaluate_for_renewal
    end
  end

  describe "private methods" do
    it "validates one membership per member" do
      membership = create(:earned_membership)
      invalid_membership = build(:earned_membership, member: membership.member)
      allow(invalid_membership).to receive(:requirements_exist)
      expect(invalid_membership.valid?).to be(false)
      invalid_membership.save
      expect(invalid_membership.persisted?).to be(false)
      member = create(:member)
      invalid_membership.member = member
      expect(invalid_membership.valid?).to be(true)
      invalid_membership.save
      expect(invalid_membership.persisted?).to be(true)
    end

    it "validates member for membership isn't on subscription" do
      subscription_member = create(:member, subscription: true)
      membership = build(:earned_membership, member: subscription_member)
      allow(membership).to receive(:requirements_exist)
      expect(membership.valid?).to be(false)
      membership.save
      expect(membership.persisted?).to be(false)
      subscription_member.update(subscription: false, subscription_id: "foo")
      expect(membership.valid?).to be(false)
      membership.save
      expect(membership.persisted?).to be(false)
      subscription_member.update(subscription: false, subscription_id: nil)
      expect(membership.valid?).to be(true)
      membership.save
      expect(membership.persisted?).to be(true)
    end

    it "validates requirements and member exists" do
      membership = build(:earned_membership, member: nil)
      allow(membership).to receive(:requirements_exist)
      expect(membership.valid?).to be(false)
      membership.save
      expect(membership.persisted?).to be(false)
      membership.member = create(:member)
      expect(membership.valid?).to be(true)
      membership.save
      expect(membership.persisted?).to be(true)

      other_membership = build(:earned_membership_no_requirements)
      expect(other_membership.valid?).to be(false)
      other_membership.save
      expect(other_membership.persisted?).to be(false)
      other_membership.requirements = build_list(:requirement, 3)
      expect(other_membership.valid?).to be(true)
      other_membership.save
      expect(other_membership.persisted?).to be(true)
    end

    it "renews member based on shortest requirement term" do
      shortest_requirement = build(:requirement, term_length: 1)
      longest_requirement = build(:requirement, term_length: 5)
      member = create(:member)
      membership = create(:earned_membership, member: member, requirements: [shortest_requirement, longest_requirement])
      membership.send(:renew_member)
      member.reload
      expect(member.get_expiration).to eq(shortest_requirement.current_term.end_date.to_i * 1000)
    end

    it "renews member on create if member benefits" do
      exp_member = create(:member, expirationTime: (Time.now - 2.months).to_i * 1000)
      membership = build(:earned_membership, member: exp_member)
      allow(membership).to receive(:requirements_exist)
      allow(membership).to receive(:get_shortest_term_end_time).and_return((Time.now + 1.year).to_i * 1000)
      expect(membership).to receive(:renew_member)
      membership.save!

      other_member = create(:member, expirationTime: (Time.now + 2.months).to_i * 1000)
      other_membership = build(:earned_membership, member: other_member)
      allow(other_membership).to receive(:requirements_exist)
      allow(other_membership).to receive(:get_shortest_term_end_time).and_return((Time.now + 1.month).to_i * 1000)
      expect(other_membership).not_to receive(:renew_member)
      other_membership.save!
    end
  end

  describe "suspend! and reactivate!" do
    let(:admin) { create(:member, :admin) }

    it "defaults new records to active status" do
      membership = create(:earned_membership)
      expect(membership.status).to eq("active")
      expect(membership).to be_active
    end

    it "suspends without deleting requirements or reports" do
      membership = create(:earned_membership_with_reports)
      requirement_count = membership.requirements.count
      report_count = membership.reports.count

      membership.suspend!(admin)
      membership.reload

      expect(membership.status).to eq("suspended")
      expect(membership).to be_suspended
      expect(membership.requirements.count).to eq(requirement_count)
      expect(membership.reports.count).to eq(report_count)
    end

    it "suspends a member who has already converted to a paid subscription (#257)" do
      subscribed_member = create(:member, subscription_id: "sub_123")
      membership = create(:earned_membership, member: subscribed_member)

      expect { membership.suspend!(admin) }.not_to raise_error
      membership.reload
      expect(membership).to be_suspended
    end

    it "logs a distinct audit event on suspend" do
      membership = create(:earned_membership)
      expect(::Service::AuditLogger).to receive(:log).with(hash_including(event_type: "earned_membership_suspended"))
      membership.suspend!(admin)
    end

    it "reactivates a suspended membership" do
      membership = create(:earned_membership)
      membership.suspend!(admin)
      membership.reactivate!(admin)
      membership.reload
      expect(membership).to be_active
    end

    it "rejects reactivating when the member currently has a paid subscription" do
      membership = create(:earned_membership)
      membership.suspend!(admin)
      membership.member.update!(subscription_id: "sub_123")

      expect { membership.reactivate!(admin) }.to raise_error(Mongoid::Errors::Validations)
      membership.reload
      expect(membership).to be_suspended
    end

    it "logs a distinct audit event on reactivate" do
      membership = create(:earned_membership)
      membership.suspend!(admin)
      expect(::Service::AuditLogger).to receive(:log).with(hash_including(event_type: "earned_membership_reactivated"))
      membership.reactivate!(admin)
    end

    it "does not run set_member_expiration while suspended" do
      membership = create(:earned_membership)
      membership.suspend!(admin)
      expect(membership).not_to receive(:renew_member)
      membership.reload.save!
    end
  end
end