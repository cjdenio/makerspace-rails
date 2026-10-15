require "rails_helper"

RSpec.describe ToolCheckoutRequestEligibility do
  let(:shop) { create(:shop) }
  let(:member) { create(:member, :current) }
  let(:prerequisite) { create(:tool, shop: shop) }
  let(:tool) { create(:tool, shop: shop, prerequisite_ids: [prerequisite.id.to_s]) }

  subject(:eligibility) { described_class.new(member: member, tool: tool) }

  it "requires every prerequisite checkout" do
    expect(eligibility).not_to be_eligible
    create(:tool_checkout, member: member, tool: prerequisite)
    expect(eligibility).to be_eligible
  end

  it "does not count a revoked prerequisite checkout" do
    create(:tool_checkout, member: member, tool: prerequisite, revoked_at: Time.current)
    expect(eligibility).not_to be_eligible
  end

  it "excludes a target with any existing checkout, including a revoked one" do
    create(:tool_checkout, member: member, tool: prerequisite)
    create(:tool_checkout, member: member, tool: tool, revoked_at: Time.current)
    expect(eligibility.error).to eq("A checkout record already exists for this tool")
  end

  it "excludes a target with an open request" do
    create(:tool_checkout, member: member, tool: prerequisite)
    ToolCheckoutRequest.create!(member: member, tool: tool, status: "open")
    expect(eligibility.error).to eq("An open request already exists for this tool")
  end

  it "excludes disabled tools and tools in disabled shops" do
    tool.update!(disabled: true)
    expect(eligibility).not_to be_eligible
    tool.update!(disabled: false)
    shop.update!(disabled: true)
    expect(eligibility).not_to be_eligible
  end

  it "allows pending members only for tools that allow pending members" do
    member.update!(status: "pending")
    tool.update!(prerequisite_ids: [])
    expect(eligibility).not_to be_eligible
    tool.update!(allow_pending: true)
    expect(eligibility).to be_eligible
  end

  it "uses supplied empty and populated ID sets without querying checkout collections" do
    tool
    expect(ToolCheckout).not_to receive(:where)
    expect(ToolCheckoutRequest).not_to receive(:where)
    preloaded = described_class.new(member: member, tool: tool,
      checkout_tool_ids: [], active_checkout_tool_ids: [prerequisite.id], open_request_tool_ids: [])
    expect(preloaded).to be_eligible
    missing = described_class.new(member: member, tool: tool,
      checkout_tool_ids: [], active_checkout_tool_ids: [], open_request_tool_ids: [])
    expect(missing.error).to include("prerequisite")
  end

end
