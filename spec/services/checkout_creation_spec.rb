require "rails_helper"

RSpec.describe CheckoutCreation do
  let(:actor) { create(:member, :current, :admin) }
  let(:member) { create(:member, :current) }
  let(:tool) { create(:tool) }
  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow_any_instance_of(ToolCheckout).to receive(:send_checkout_slack_notification)
    allow_any_instance_of(ToolCheckout).to receive(:announce_checkout_success)
    allow(Service::ErrorReporter).to receive(:notify)
  end

  def create_checkout(**options, &block)
    described_class.create!(actor_id: actor.id, member_id: member.id, tool_id: tool.id,
      shop_id: tool.shop_id, source: "slack", **options, &block)
  end

  it "rechecks authority inside the shared member/tool lock" do
    actor
    expect { create_checkout { actor.update!(role: "member") } }.to raise_error(Error::Forbidden)
    expect(ToolCheckout.count).to eq(0)
    expect(REDIS).to have_received(:set).with("checkout_request_lock/#{member.id}/#{tool.id}", anything, nx: true, ex: 30)
  end

  it "awards a silent quarter credit when an additional approver completes a checkout" do
    actor.update!(role: "member")
    CheckoutApprover.create!(member: actor, tool_ids: [tool.id.to_s])

    checkout = create_checkout

    expect(VolunteerCredit.find(checkout.reload.volunteer_credit_id)).to have_attributes(
      member_id: actor.id, credit_value: 0.25, status: "approved")
  end

  it "serializes and revalidates an additional approver's authority before insertion" do
    actor.update!(role: "member")
    assignment = CheckoutApprover.create!(member: actor, tool_ids: [tool.id.to_s])

    expect { create_checkout { assignment.destroy! } }.to raise_error(Error::Forbidden)

    expect(ToolCheckout.count).to eq(0)
    expect(REDIS).to have_received(:set).with(
      "checkout_approver_lock/#{actor.id}", anything, nx: true, ex: 30
    )
  end

  it "does not report a completed checkout as failed when credit persistence fails" do
    actor.update!(role: "member")
    CheckoutApprover.create!(member: actor, tool_ids: [tool.id.to_s])
    allow(CheckoutApproverCredit).to receive(:award!).and_raise(StandardError)

    checkout = create_checkout

    expect(checkout).to be_persisted
    expect(Service::ErrorReporter).to have_received(:notify).with(
      "Checkout notification failed", context: { error_class: "StandardError" })
  end

  it "rejects unmet and revoked prerequisites, then accepts a valid prerequisite" do
    prerequisite = create(:tool)
    tool.update!(prerequisite_ids: [prerequisite.id.to_s])
    expect { create_checkout }.to raise_error(Error::UnprocessableEntity, /prerequisite/)
    row = create(:tool_checkout, member: member, tool: prerequisite, revoked_at: Time.current)
    expect { create_checkout }.to raise_error(Error::UnprocessableEntity, /prerequisite/)
    row.update!(revoked_at: nil)
    expect { create_checkout }.to change(ToolCheckout, :count).by(1)
  end

  it "rejects an unavailable tool, ineligible member and duplicate checkout" do
    tool.update!(disabled: true)
    expect { create_checkout }.to raise_error(Error::UnprocessableEntity, /unavailable/)
    tool.update!(disabled: false)
    member.update!(status: "pending")
    expect { create_checkout }.to raise_error(Error::UnprocessableEntity, /membership/)
    tool.update!(allow_pending: true)
    create_checkout
    expect { create_checkout }.to raise_error(Error::UnprocessableEntity, /already exists/)
  end

  it "rejects stale request state and cross-tool requests inside the lock" do
    row = ToolCheckoutRequest.create!(member: member, tool: tool)
    expect { create_checkout(request_id: row.id) { row.update!(status: "deleted") } }.to raise_error(Error::UnprocessableEntity, /no longer open/)
    other = ToolCheckoutRequest.create!(member: member, tool: create(:tool))
    expect { create_checkout(request_id: other.id) }.to raise_error(Error::UnprocessableEntity)
    expect(ToolCheckout.count).to eq(0)
  end

  it "closes every satisfied request and retains audit even when notification fails" do
    earlier = ToolCheckoutRequest.create!(member: member, tool: tool)
    row = ToolCheckoutRequest.create!(member: member, tool: tool)
    allow_any_instance_of(ToolCheckout).to receive(:send_checkout_slack_notification).and_raise(StandardError)
    checkout = create_checkout(request_id: row.id)
    expect(row.reload).to have_attributes(status: "closed", checked_out_id: checkout.id)
    expect(earlier.reload.status).to eq('closed')
    expect(AuditLog.where(resource_id: checkout.id, event_type: "tool_checkout_created")).to exist
  end

  it "rejects lock contention without creating a checkout" do
    allow(REDIS).to receive(:set).and_return(false)
    expect { create_checkout }.to raise_error(Error::UnprocessableEntity, /already being processed/)
    expect(ToolCheckout.count).to eq(0)
    expect(REDIS).not_to have_received(:eval)
  end

  it "preserves approval and request closure when canvas enqueueing fails" do
    row = ToolCheckoutRequest.create!(member: member, tool: tool)
    allow(ToolCheckoutSlackCanvasSyncJob).to receive(:perform_later).and_raise(StandardError)
    checkout = create_checkout(request_id: row.id)
    expect(checkout).to be_persisted
    expect(row.reload).to have_attributes(status: "closed", checked_out_id: checkout.id)
    expect(Service::ErrorReporter).to have_received(:notify).with("Checkout notification failed", context: { error_class: "StandardError" })
  end

  it "rechecks target membership after acquiring the lock" do
    expect { create_checkout { member.update!(status: "suspended") } }.to raise_error(Error::UnprocessableEntity)
    expect(ToolCheckout.count).to eq(0)
  end

  it "revalidates a displayed requestable tool immediately before request insertion" do
    expect do
      CheckoutRequestCreation.create!(member_id: member.id, tool_id: tool.id, shop_id: tool.shop_id) { tool.update!(disabled: true) }
    end.to raise_error(Error::UnprocessableEntity, /unavailable/)
    expect(ToolCheckoutRequest.count).to eq(0)
  end

end
