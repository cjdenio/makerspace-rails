require 'rails_helper'

RSpec.describe CheckoutExpirationManagement, requires_transactions: true do
  include ActiveSupport::Testing::TimeHelpers
  let(:actor) { create(:member, :admin, :current) }
  let(:member) { create(:member, :current) }
  let(:tool) { create(:tool, checkout_expiration_years: 1) }
  let(:checkout) { create(:tool_checkout, member: member, tool: tool, approved_by: actor) }
  before do
    @lock_tokens = {}
    allow(REDIS).to receive(:set) { |key, token, **_options| @lock_tokens[key] = token; true }
    allow(REDIS).to receive(:get).and_call_original
    allow(REDIS).to receive(:get).with(%r{^checkout_request_lock/}) { |key| @lock_tokens[key] }
    allow(REDIS).to receive(:eval).and_return(1)
    allow(Service::SlackConnector).to receive(:send_slack_message)
  end

  it 'updates dates, resets notices, audits, and rejects stale edits' do
    checkout.set(expiration_notice_state: { 'email' => 2 })
    date = Date.current + 30
    described_class.update!(actor: actor, checkout: checkout, expires_on: date.iso8601, revision: 0)
    expect(checkout.reload.expires_on).to eq(date)
    expect(checkout.expiration_revision).to eq(1)
    expect(checkout.expiration_notice_state).to eq({})
    expect(AuditLog.where(event_type: 'tool_checkout_expiration_changed', resource_id: checkout.id)).to exist
    expect { described_class.update!(actor: actor, checkout: checkout, expires_on: nil, revision: 0) }.to raise_error(Error::Conflict)
    described_class.update!(actor: actor, checkout: checkout, expires_on: nil, revision: 1)
    expect(checkout.reload.expires_on).to be_nil
  end

  it 'preserves delivery state when assigning the same date' do
    checkout.set(expiration_notice_state: { 'email' => 1 })
    described_class.update!(actor: actor, checkout: checkout, expires_on: checkout.expires_on.iso8601, revision: 0)
    expect(checkout.reload.expiration_notice_state).to eq('email' => 1)
    expect(checkout.expiration_revision).to eq(0)
  end

  it 'limits managers to their own shops and excludes ordinary approvers' do
    outsider = create(:member, :resource_manager, :current)
    expect { described_class.update!(actor: outsider, checkout: checkout, expires_on: nil, revision: 0) }.to raise_error(Error::Forbidden)
    outsider.update!(resource_manager_shop_ids: [tool.shop_id.to_s])
    described_class.update!(actor: outsider, checkout: checkout, expires_on: nil, revision: 0)
    expect(checkout.reload.expires_on).to be_nil
  end

  it 'bulk updates current records while preserving revocation and superseded history' do
    current = checkout
    expired = create(:tool_checkout, tool: tool, expires_on: Date.current - 2)
    revoked = create(:tool_checkout, tool: tool, revoked_at: Time.current)
    historical = create(:tool_checkout, tool: tool, superseded_by_id: current.id)
    old_dates = [revoked.expires_on, historical.expires_on]
    date = (Date.current + 60).iso8601
    expect(CheckoutMutationLock).to receive(:with).once.with(member_id: 'catalog', tool_id: tool.shop_id, persistent: true).and_call_original
    expect(described_class.bulk_update!(actor: actor, tool: tool, expires_on: date)).to eq(2)
    expect(REDIS).to have_received(:set).with("checkout_request_lock/catalog/#{tool.shop_id}", anything, nx: true)
    expect([current.reload.expires_on.iso8601, expired.reload.expires_on.iso8601]).to eq([date, date])
    expect([revoked.reload.expires_on, historical.reload.expires_on]).to eq(old_dates)
  end

  it 'rolls back the bulk transaction if persistent ownership is lost before commit' do
    original = checkout.expires_on
    allow(REDIS).to receive(:get).with("checkout_request_lock/catalog/#{tool.shop_id}") do |key|
      @ownership_checks = @ownership_checks.to_i + 1
      @ownership_checks == 1 ? @lock_tokens[key] : nil
    end
    expect { described_class.bulk_update!(actor: actor, tool: tool, expires_on: (Date.current + 60).iso8601) }
      .to raise_error(Error::Conflict, /ownership was lost/)
    expect(checkout.reload.expires_on).to eq(original)
    expect(AuditLog.where(event_type: 'tool_checkout_expiration_changed', resource_id: checkout.id)).not_to exist
  end

  it 'renews an expired checkout transactionally without losing its history' do
    old = checkout
    old.set(expires_on: Date.current - 2)
    expect(ToolCheckoutSlackCanvasSyncJob).to receive(:perform_later).with(tool.shop_id.to_s).once
    expect(ToolCheckoutSlackCanvasSyncJob).not_to receive(:perform_later).with(tool.shop_id.to_s, anything, 'add')
    renewed = CheckoutCreation.create!(actor_id: actor.id, member_id: member.id, tool_id: tool.id,
      shop_id: tool.shop_id, source: 'portal')
    expect(renewed.renewed_from_id).to eq(old.id)
    expect(old.reload.superseded_by_id).to eq(renewed.id)
    expect(renewed).to be_active
    expect { described_class.update!(actor: actor, checkout: old, expires_on: nil, revision: 0) }.to raise_error(Error::Conflict)
    expect { ToolCheckoutReinstatement.reinstate!(actor: actor, revoked_checkout: old, reason: 'No') }.to raise_error(Error::UnprocessableEntity)
  end

  it 'uses each constituent policy in group renewal and preserves the source group' do
    old = checkout
    old.set(expires_on: Date.current - 2)
    other = create(:tool, shop: tool.shop, checkout_expiration_years: 5)
    group = ToolGroup.create!(shop: tool.shop, name: 'Training kit', included_tool_ids: [tool.id.to_s, other.id.to_s],
      checkout_training_plan_url: 'https://example.com/training')
    result = ToolGroupCheckout.approve!(actor: actor, member: member, group: group, revision: group.revision)
    rows = result[:checkouts].index_by(&:tool_id)
    today = Time.current.in_time_zone(CheckoutExpiration::ZONE).to_date
    expect(rows[tool.id].expires_on).to eq(today.advance(years: 1))
    expect(rows[other.id].expires_on).to eq(today.advance(years: 5))
    expect(rows[tool.id].renewed_from_id).to eq(old.id)
    expect(rows[tool.id].checkout_training_plan_url).to eq(group.checkout_training_plan_url)
  end

  it 'assigns the current tool policy on reinstatement, leaving the revoked date intact' do
    old = checkout
    old.update!(revoked_at: Time.current)
    old_date = old.expires_on
    tool.update!(checkout_expiration_years: 3)
    restored = ToolCheckoutReinstatement.reinstate!(actor: actor, revoked_checkout: old, reason: 'Training reviewed')
    expect(restored.expires_on).to eq(Time.current.in_time_zone(CheckoutExpiration::ZONE).to_date.advance(years: 3))
    expect(old.reload.expires_on).to eq(old_date)
    expect(restored.reinstated_from_id).to eq(old.id)
  end

  it 'does not let expiration bypass a revocation' do
    checkout.update!(revoked_at: Time.current)
    expect(ToolCheckoutRequestEligibility.new(member: member, tool: tool)).not_to be_eligible
  end
end
