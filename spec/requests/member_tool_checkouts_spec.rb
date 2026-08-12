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
end
