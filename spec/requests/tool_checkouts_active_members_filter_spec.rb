require "rails_helper"

RSpec.describe "Listing tool checkouts for active members only", type: :request do
  let(:tool) { create(:tool) }
  let(:admin) { create(:member, :current, :admin) }
  let(:expired_at) { (Time.now.to_i - 86_400) * 1000 }
  let!(:current_member) { create(:member, :current, firstname: "Current") }
  let!(:expired_member) { create(:member, firstname: "Expired", expirationTime: expired_at) }
  let!(:revoked_member) { create(:member, :current, firstname: "Revoked", status: "revoked") }
  let!(:pending_member) { create(:member, :current, firstname: "Pending", status: "pending") }

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(Service::SlackConnector).to receive(:send_slack_message)
    [current_member, expired_member, revoked_member, pending_member].each do |member|
      ToolCheckout.create!(member: member, tool: tool, checked_out_at: Time.current)
    end
    sign_in admin
  end

  def listed_names(params = {})
    get "/api/admin/tool_checkouts", params: params
    JSON.parse(response.body).map { |row| row["memberName"] }
  end

  it "keeps returning every checkout unless asked to filter" do
    expect(listed_names).to contain_exactly(*[current_member, expired_member, revoked_member, pending_member].map(&:fullname))
  end

  it "returns only members with an active status and an unexpired term when asked" do
    expect(listed_names(active_members_only: "true")).to contain_exactly(current_member.fullname, pending_member.fullname)
  end

  it "combines with the tool and active-checkout filters" do
    other_tool = create(:tool)
    ToolCheckout.create!(member: current_member, tool: other_tool, checked_out_at: Time.current)

    expect(listed_names(active_members_only: "true", tool_id: other_tool.id.to_s, active: "true")).to eq([current_member.fullname])
  end
end
