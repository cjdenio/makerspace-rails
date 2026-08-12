require "rails_helper"

RSpec.describe "Resource-scoped checkout authorization", type: :request do
  let(:managed_shop) { create(:shop) }
  let(:outside_shop) { create(:shop) }
  let(:managed_tool) { create(:tool, shop: managed_shop) }
  let(:approved_outside_tool) { create(:tool, shop: outside_shop) }
  let(:unrelated_outside_tool) { create(:tool, shop: outside_shop) }
  let(:target_member) { create(:member, :current) }
  let(:resource_manager) do
    create(
      :member,
      :resource_manager,
      :current,
      resource_manager_shop_ids: [managed_shop.id.to_s]
    )
  end

  before do
    CheckoutApprover.create!(
      member: resource_manager,
      tool_ids: [approved_outside_tool.id.to_s]
    )
    sign_in resource_manager
  end

  it "allows ordinary approval for an explicitly assigned tool outside the RM shop" do
    post "/api/admin/tool_checkouts", params: {
      member_id: target_member.id.to_s,
      tool_id: approved_outside_tool.id.to_s
    }

    expect(response).to have_http_status(:ok)
  end

  it "rejects approval for unrelated tools outside the RM shop" do
    post "/api/admin/tool_checkouts", params: {
      member_id: target_member.id.to_s,
      tool_id: unrelated_outside_tool.id.to_s
    }

    expect(response).to have_http_status(:forbidden)
  end

  it "does not grant catalog management for the outside approver assignment" do
    put "/api/admin/tools/#{approved_outside_tool.id}", params: { name: "Renamed" }

    expect(response).to have_http_status(:forbidden)
    expect(approved_outside_tool.reload.name).not_to eq("Renamed")
  end
end
