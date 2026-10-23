require "rails_helper"

# householdSetupNeeded is staff information (same audience as provisioning):
# admins and board see it on a member's profile, the member and others do not.
RSpec.describe "Household setup flag", type: :request do
  let(:admin) { create(:member, :current, :admin) }
  let(:board) { create(:member, :current, role: "board_member") }
  let(:member) { create(:member, :current) }
  let(:other) { create(:member, :current) }

  before do
    allow(REDIS).to receive(:set).and_return(true)
    create(:invoice, member: member, resource_id: member.id.to_s, resource_class: "member",
      plan_id: "household-membership-one-month-recurring")
  end

  def profile_as(viewer, target)
    sign_in viewer
    get "/api/members/#{target.id}"
    JSON.parse(response.body)
  end

  it "is true for an admin viewing a household-plan member with no household" do
    expect(profile_as(admin, member)["householdSetupNeeded"]).to be(true)
  end

  it "is true for a board member" do
    expect(profile_as(board, member)["householdSetupNeeded"]).to be(true)
  end

  it "is false once the household exists" do
    member.update_attributes!(groupName: member.id.to_s)
    expect(profile_as(admin, member)["householdSetupNeeded"]).to be(false)
  end

  it "is not returned to the member themselves" do
    expect(profile_as(member, member)).not_to have_key("householdSetupNeeded")
  end
end
