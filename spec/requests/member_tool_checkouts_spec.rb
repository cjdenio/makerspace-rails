require "rails_helper"

RSpec.describe "Member tool checkouts", type: :request do
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop) }
  let(:hidden_tool) { create(:tool, shop: shop, disabled: true) }
  let!(:checkout) { create(:tool_checkout, member: member, tool: hidden_tool) }

  before { sign_in member }

  it "includes active hidden-tool checkouts only when requested by the member view" do
    get "/api/tool_checkouts", params: { active: true }
    expect(JSON.parse(response.body)).to be_empty

    get "/api/tool_checkouts", params: { active: true, include_hidden: true }
    row = JSON.parse(response.body).first
    expect(row).to include(
      "id" => checkout.id.to_s,
      "shopWikiUrl" => shop.effective_wiki_url
    )
  end

  it "includes notes for an active hidden tool in the member view" do
    hidden_tool.set(notes: "Hidden cabinet combination")
    get "/api/tool_checkouts", params: { active: true, include_hidden: true }
    expect(JSON.parse(response.body).first['toolNotes']).to eq("Hidden cabinet combination")
  end

  describe "tool notes visibility (#189)" do
    let(:noted_tool) { create(:tool, shop: shop, notes: "Combo: 9-8-7") }

    it "includes the tool's notes for a member with an active checkout on it" do
      create(:tool_checkout, member: member, tool: noted_tool)

      get "/api/tool_checkouts", params: { active: true }

      row = JSON.parse(response.body).find { |r| r["toolId"] == noted_tool.id.to_s }
      expect(row["toolNotes"]).to eq("Combo: 9-8-7")
    end

    it "omits the tool's notes once the checkout is revoked" do
      revoked = create(:tool_checkout, member: member, tool: noted_tool, revoked_at: Time.current)

      get "/api/tool_checkouts", params: { active: false }

      row = JSON.parse(response.body).find { |r| r["id"] == revoked.id.to_s }
      expect(row).not_to have_key("toolNotes")
    end
  end
end
