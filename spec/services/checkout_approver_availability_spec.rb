require 'rails_helper'
RSpec.describe CheckoutApproverSerializer do
  it 'keeps same-named tools and availability keyed by tool identity' do
    first = create(:tool, shop: create(:shop), out_of_service: false)
    other_id = BSON::ObjectId.new
    Tool.collection.insert_one(_id: other_id, name: first.name, shop_id: create(:shop).id, out_of_service: true)
    approver = CheckoutApprover.new(tool_ids: [first.id.to_s, other_id.to_s])
    tools = described_class.new(approver).serializable_hash[:tools]
    expect(tools.map { |t| t[:name] }.uniq).to eq([first.name])
    expect(tools.to_h { |t| [t[:id], t[:outOfService]] }).to eq(first.id.to_s => false, other_id.to_s => true)
  end
end
