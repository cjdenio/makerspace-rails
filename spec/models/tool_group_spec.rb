require 'rails_helper'

RSpec.describe ToolGroup do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:group) { described_class.new(shop: shop, name: 'Starter tools', included_tool_ids: [tool.id.to_s]) }

  it 'defaults to an unarchived group with all opt-in flags disabled' do
    expect(group).to be_valid
    expect([group.archived, group.requestable, group.reservable, group.announce]).to eq([false] * 4)
    expect(group.revision).to eq(1)
  end

  it 'requires disjoint physical tools from one shop' do
    group.included_tool_ids = []
    expect(group).not_to be_valid
    group.included_tool_ids = [tool.id.to_s]
    group.prerequisite_ids = [tool.id.to_s]
    expect(group).not_to be_valid
    group.prerequisite_ids = [create(:tool).id.to_s]
    expect(group).not_to be_valid
    group.prerequisite_ids = []
    group.included_tool_ids = [group.id.to_s]
    expect(group).not_to be_valid
  end

  it 'shares case-insensitive names and protects physical references' do
    group.name = tool.name.upcase
    expect(group).not_to be_valid
    group.name = 'Starter tools'
    group.save!
    expect(Tool.new(shop: shop, name: 'STARTER TOOLS')).not_to be_valid
    expect(described_class.new(shop: shop, name: 'STARTER TOOLS', included_tool_ids: [tool.id.to_s])).not_to be_valid
    expect { tool.destroy! }.to raise_error(Error::Conflict)
    tool.shop = create(:shop)
    expect(tool).not_to be_valid
  end
end
