require 'rails_helper'

RSpec.describe ToolCheckout do
  include ActiveSupport::Testing::TimeHelpers
  let(:member) { create(:member, :current) }
  let(:tool) { create(:tool) }

  around { |example| travel_to(Time.utc(2026, 10, 19, 16)) { example.run } }

  it 'keeps legacy missing expiration fields valid' do
    row = create(:tool_checkout, member: member, tool: tool)
    row.unset(:expires_on, :superseded_by_id)
    expect(row.reload).to be_active
    expect(described_class.valid_at.pluck(:id)).to include(row.id)
  end

  it 'is valid through Eastern midnight, including the reservation end boundary' do
    row = create(:tool_checkout, member: member, tool: tool, expires_on: Date.new(2026, 10, 19))
    expect(row.valid_through?(Time.utc(2026, 10, 20, 4))).to be true
    expect(row.valid_through?(Time.utc(2026, 10, 20, 4, 0, 1))).to be false
    travel_to(Time.utc(2026, 10, 20, 4))
    expect(row).not_to be_active
    expect(described_class.valid_at.pluck(:id)).not_to include(row.id)
  end

  it 'uses local midnight across the daylight saving transition' do
    row = build(:tool_checkout, tool: tool, expires_on: Date.new(2026, 11, 1))
    expect(row.valid_through?(Time.utc(2026, 11, 2, 5))).to be true
    expect(row.valid_through?(Time.utc(2026, 11, 2, 5, 0, 1))).to be false
  end

  (1..5).each do |years|
    it "assigns #{years} calendar years only on creation" do
      tool.update!(checkout_expiration_years: years)
      row = create(:tool_checkout, member: member, tool: tool)
      expect(row.expires_on).to eq(Date.new(2026 + years, 10, 19))
      tool.update!(checkout_expiration_years: nil)
      expect(row.reload.expires_on).to eq(Date.new(2026 + years, 10, 19))
    end
  end

  it 'rejects fractional, out-of-range, and malformed expiration policies before coercion' do
    [0, 6, 1.5, true, '1.5', 'garbage', ''].each do |value|
      tool.checkout_expiration_years = value
      expect(tool).not_to be_valid
    end
    tool.checkout_expiration_years = nil
    expect(tool).to be_valid
  end

  it 'clamps a leap-day anniversary' do
    tool.update!(checkout_expiration_years: 1)
    row = create(:tool_checkout, member: member, tool: tool, checked_out_at: Time.utc(2024, 2, 29, 16))
    expect(row.expires_on).to eq(Date.new(2025, 2, 28))
  end

  it 'uses the originating group as a fallback, with live tool overrides' do
    group = ToolGroup.create!(name: 'Training group', shop: tool.shop, included_tool_ids: [tool.id.to_s], checkout_training_plan_url: 'https://example.com/group')
    row = create(:tool_checkout, member: member, tool: tool, group_id: group.id)
    expect(row.checkout_training_plan_url).to eq('https://example.com/group')
    tool.update!(checkout_training_plan_url: 'https://example.com/tool')
    expect(row.checkout_training_plan_url).to eq('https://example.com/tool')
  end

  it 'does not infer fallback training links from present-day group membership' do
    ToolGroup.create!(shop: tool.shop, name: 'Unrelated group', included_tool_ids: [tool.id.to_s],
      checkout_training_plan_url: 'https://example.com/unrelated')
    row = create(:tool_checkout, member: member, tool: tool, group_id: BSON::ObjectId.new)
    expect(row.checkout_training_plan_url).to be_nil
  end

  it 'excludes expired checkout privileges without treating expiration as revocation' do
    row = create(:tool_checkout, member: member, tool: tool, expires_on: Date.new(2026, 10, 18))
    expect(ToolCheckoutRequestEligibility.new(member: member, tool: tool)).to be_eligible
    expect(tool.notes_visible_to?(member)).to be false
    expect(row.revoked_at).to be_nil
  end

  it 'rejects unsafe or malformed training links and normalizes blank values' do
    ['javascript:alert(1)', '/relative', 'https://', 'https://user:password@example.com'].each do |url|
      tool.checkout_training_plan_url = url
      expect(tool).not_to be_valid
    end
    tool.update!(checkout_training_plan_url: '  ')
    expect(tool.checkout_training_plan_url).to be_nil
  end
end
