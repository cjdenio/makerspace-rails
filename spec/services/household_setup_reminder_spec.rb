require 'rails_helper'

RSpec.describe HouseholdSetupReminder do
  let(:member) { create(:member, :current) }

  def bill_on(plan_id, owner = member)
    create(:invoice, member: owner, resource_id: owner.id.to_s, resource_class: "member", plan_id: plan_id)
  end

  describe "Member#household_setup_needed?" do
    it "is true for a current member whose latest invoice is on a household plan and who has no household" do
      bill_on("household-membership-one-month-recurring")
      expect(member.household_setup_needed?).to be(true)
    end

    it "is true for a pending member paid on a household plan with no expiration yet" do
      pending_member = create(:member, status: 'pending', expirationTime: nil)
      bill_on("2024_household-membership-one-month-recurring", pending_member)
      expect(pending_member.household_setup_needed?).to be(true)
    end

    it "is false when the latest invoice is not a household plan" do
      bill_on("household-membership-one-month-recurring").update_attributes!(settled_at: 2.days.ago)
      bill_on("membership-one-month-recurring")
      expect(member.household_setup_needed?).to be(false)
    end

    it "is false for a member who has no invoices" do
      expect(member.household_setup_needed?).to be(false)
    end

    it "is false once the member is the primary of a household" do
      bill_on("household-membership-one-month-recurring")
      member.update_attributes!(groupName: member.id.to_s)
      expect(member.household_setup_needed?).to be(false)
    end

    it "is false for a secondary household member" do
      primary = create(:member, :current)
      bill_on("household-membership-one-month-recurring", primary)
      primary.update_attributes!(groupName: primary.id.to_s)
      secondary = create(:member, :current, groupName: primary.id.to_s)
      bill_on("household-membership-one-month-recurring", secondary)
      expect(secondary.household_setup_needed?).to be(false)
    end

    it "is false for an expired membership" do
      expired = create(:member, :expired)
      bill_on("household-membership-one-month-recurring", expired)
      expect(expired.household_setup_needed?).to be(false)
    end

    it "is false for an inactive or revoked member" do
      %w[inactive revoked].each do |status|
        other = create(:member, :current, status: status)
        bill_on("household-membership-one-month-recurring", other)
        expect(other.household_setup_needed?).to be(false)
      end
    end

    it "is not fooled by a legacy groupName that points at no member" do
      member.update_attributes!(groupName: "legacy-partner-group")
      bill_on("household-membership-one-month-recurring")
      expect(member.household_setup_needed?).to be(true)
    end
  end

  describe ".notify" do
    before do
      allow(::Service::SlackConnector).to receive(:enque_message)
    end

    it "queues a Slack reminder naming the member and linking to their profile" do
      bill_on("household-membership-one-month-recurring")

      expect(described_class.notify(member, trigger: :fob)).to be(true)

      expect(::Service::SlackConnector).to have_received(:enque_message).with(
        a_string_including(member.fullname, "Create Household", "Add Secondary Member", "/members/#{member.id}", "a key fob was registered"),
        ::Service::SlackConnector.members_relations_channel,
        a_string_including("household_setup_reminder.#{member.id}.fob")
      )
    end

    it "uses renewal wording for the renewal trigger" do
      bill_on("household-membership-one-month-recurring")
      described_class.notify(member, trigger: :renewal)
      expect(::Service::SlackConnector).to have_received(:enque_message).with(a_string_including("the membership was renewed"), anything, anything)
    end

    it "does nothing for a member who does not need a household" do
      expect(described_class.notify(member, trigger: :fob)).to be(false)
      expect(::Service::SlackConnector).not_to have_received(:enque_message)
    end

    it "does not raise when Slack queueing fails" do
      bill_on("household-membership-one-month-recurring")
      allow(::Service::SlackConnector).to receive(:enque_message).and_raise("redis down")
      expect(described_class.notify(member, trigger: :fob)).to be(false)
    end
  end

  describe "when a key fob is registered" do
    it "reminds staff to create the household for a household-plan member" do
      pending_member = create(:member, :current, status: 'pending')
      bill_on("household-membership-one-month-recurring", pending_member)
      allow(::Service::SlackConnector).to receive(:enque_message)

      create(:card, member: pending_member)

      expect(::Service::SlackConnector).to have_received(:enque_message).with(
        a_string_including("#{pending_member.fullname}", "has no household yet"), anything, a_string_including("household_setup_reminder")
      )
    end

    it "does not remind for an ordinary member" do
      ordinary = create(:member, :current)
      allow(::Service::SlackConnector).to receive(:enque_message)

      create(:card, member: ordinary)

      expect(::Service::SlackConnector).not_to have_received(:enque_message).with(a_string_including("has no household yet"), anything, anything)
    end
  end
end
