require 'rails_helper'

RSpec.describe Admin::GroupsController, type: :controller do
  set_devise_mapping
  let(:admin) { create(:member, :admin) }

  before { sign_in admin }

  describe "POST #create" do
    it "rejects a primary who already has a real household" do
      existing_primary = create(:member)
      create(:invoice, member: existing_primary, resource_id: existing_primary.id.to_s,
        resource_class: "member", plan_id: "household-membership-one-month-recurring")
      existing_primary.update_attributes!(groupName: existing_primary.id.to_s)
      Group.create!(groupName: existing_primary.id.to_s, groupRep: existing_primary.fullname,
        expiry: existing_primary.expirationTime)

      post :create, params: { primary_member_id: existing_primary.id.to_s }, format: :json

      expect(response).to have_http_status(422)
      expect(Group.where(groupName: existing_primary.id.to_s).count).to eq(1)
    end

    # groupName predates the household feature and was also used as a
    # free-text organizational/partner-group label (see Member#household_role
    # and #313/#314) -- a member carrying one of those old labels isn't
    # really in a household, so it must not block creating a real one for
    # them.
    it "allows creating a household for a primary whose groupName is a legacy non-household label" do
      primary = create(:member, groupName: "Autodesk")
      create(:invoice, member: primary, resource_id: primary.id.to_s,
        resource_class: "member", plan_id: "household-membership-one-month-recurring")

      post :create, params: { primary_member_id: primary.id.to_s }, format: :json

      expect(response).to have_http_status(201)
      expect(primary.reload.groupName).to eq(primary.id.to_s)
    end
  end

  describe "POST #add_member" do
    let(:primary) do
      member = create(:member)
      create(:invoice, member: member, resource_id: member.id.to_s,
        resource_class: "member", plan_id: "household-membership-one-month-recurring")
      member.update_attributes!(groupName: member.id.to_s)
      Group.create!(groupName: member.id.to_s, groupRep: member.fullname, expiry: member.expirationTime)
      member
    end
    let(:group) { Group.find_by(groupName: primary.id.to_s) }

    it "rejects a secondary who already has a real household" do
      other_primary = create(:member)
      create(:invoice, member: other_primary, resource_id: other_primary.id.to_s,
        resource_class: "member", plan_id: "household-membership-one-month-recurring")
      other_primary.update_attributes!(groupName: other_primary.id.to_s)
      secondary = create(:member, groupName: other_primary.id.to_s)

      post :add_member, params: { id: group.id.to_s, secondary_member_id: secondary.id.to_s }, format: :json

      expect(response).to have_http_status(422)
    end

    it "allows adding a secondary whose groupName is a legacy non-household label" do
      secondary = create(:member, groupName: "GSWT")

      post :add_member, params: { id: group.id.to_s, secondary_member_id: secondary.id.to_s }, format: :json

      expect(response).to have_http_status(200)
      expect(secondary.reload.groupName).to eq(primary.id.to_s)
    end
  end
end
