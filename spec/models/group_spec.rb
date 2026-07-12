require 'rails_helper'

RSpec.describe Group, type: :model do
  let(:group) { build(:group) }

  describe "Mongoid validations" do
    it { is_expected.to be_mongoid_document }
    it { is_expected.to be_stored_in(collection: 'groups') }

    it { is_expected.to have_field(:groupRep) }
    it { is_expected.to have_field(:groupName).of_type(String) }
    it { is_expected.to have_field(:expiry).of_type(Integer) }
  end

  describe "ActiveModel validations" do
    it { is_expected.to belong_to(:member).with_foreign_key("groupRep") }
    it { is_expected.to have_many(:active_members).as_inverse_of(:group).with_foreign_key("groupName")}

    # with_primary_key being released in next version of RSpec
    # it { is_expected.to belong_to(:member).with_primary_key("fullname").with_foreign_key("groupRep") }
    # it { is_expected.to have_many(:active_members).with_primary_key("groupName").as_inverse_of(:group).with_foreign_key("groupName")}
  end
  it "has a valid factory" do
    expect(create(:group)).to be_valid
  end

  # describe "callbacks" do
  #   it { expect(group).to callback(:update_active_members).after(:update) }
  #   it { expect(group).to callback(:update_active_members).after(:create) }
  # end

  describe "private methods" do
    it "Updates group expiration and access card" do
      primary = create(:member)
      expired_member = create(:member, :expired, groupName: primary.id.to_s)
      card = create(:card, member: expired_member)
      # Create group owned by primary — expired_member is a secondary active_member
      group = create(:group, groupRep: primary.fullname, groupName: primary.id.to_s)
      group_expiration = group.expiry
      # after_create triggers update_active_members → verify_group_expiry on secondaries
      expect(expired_member.reload.expirationTime).to eq(group_expiration)
      # Card expiry syncs via Card#set_expiration (after_save on card, not on member).
      # Re-save the card to fire the callback with the updated member expirationTime.
      card.reload.save!
      expect(card.reload.expiry).to eq(group_expiration)
    end
  end
end
