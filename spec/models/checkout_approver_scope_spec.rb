require "rails_helper"

RSpec.describe CheckoutApprover do
  let(:member) { create(:member, :current) }
  let(:first_shop) { create(:shop) }
  let(:second_shop) { create(:shop) }
  let(:shop_tool) { create(:tool, shop: first_shop) }
  let(:specific_tool) { create(:tool, shop: second_shop) }
  let(:other_tool) { create(:tool, shop: second_shop) }

  it "combines whole-shop and individual-tool assignments" do
    approver = described_class.create!(
      member: member,
      shop_ids: [first_shop.id.to_s],
      tool_ids: [specific_tool.id.to_s]
    )

    expect(approver.can_approve_tool?(shop_tool)).to be(true)
    expect(approver.can_approve_tool?(specific_tool)).to be(true)
    expect(approver.can_approve_tool?(other_tool)).to be(false)
  end

  it "requires at least one assignment" do
    approver = described_class.new(member: member)
    expect(approver).not_to be_valid
  end
end
