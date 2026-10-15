require 'rails_helper'

RSpec.describe Tool, '#notes_visible_to?' do
  let(:shop) { create(:shop) }
  let(:other_shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop, notes: 'Combo: 12-34-56') }
  let(:stranger) { create(:member, :current) }

  it 'is false for a stranger with no relationship to the tool' do
    expect(tool.notes_visible_to?(stranger)).to be(false)
  end

  it 'is false for nil' do
    expect(tool.notes_visible_to?(nil)).to be(false)
  end

  it 'is true for an admin' do
    expect(tool.notes_visible_to?(create(:member, :admin, :current))).to be(true)
  end

  it 'is true for a board member' do
    expect(tool.notes_visible_to?(create(:member, :board_member, :current))).to be(true)
  end

  it 'is true for a resource manager of the tool\'s shop' do
    rm = create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
    expect(tool.notes_visible_to?(rm)).to be(true)
  end

  it 'is false for a resource manager of a different shop' do
    rm = create(:member, :resource_manager, :current, resource_manager_shop_ids: [other_shop.id.to_s])
    expect(tool.notes_visible_to?(rm)).to be(false)
  end

  it 'is true for a checkout approver assigned to the tool' do
    approver = create(:member, :current)
    create(:checkout_approver, member: approver, tool_ids: [tool.id.to_s])
    expect(tool.notes_visible_to?(approver)).to be(true)
  end

  it 'is true for a member with an active checkout on the tool' do
    member = create(:member, :current)
    create(:tool_checkout, member: member, tool: tool)
    expect(tool.notes_visible_to?(member)).to be(true)
  end

  it 'is false for a member whose checkout on the tool has been revoked' do
    member = create(:member, :current)
    create(:tool_checkout, member: member, tool: tool, revoked_at: Time.current)
    expect(tool.notes_visible_to?(member)).to be(false)
  end

  it 'is false for a member with only an open, not-yet-approved checkout request' do
    member = create(:member, :current)
    ToolCheckoutRequest.create!(member: member, tool: tool, status: 'open')
    expect(tool.notes_visible_to?(member)).to be(false)
  end
end
