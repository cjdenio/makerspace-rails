require "rails_helper"

RSpec.describe CheckoutRequestDecision do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:requester) { create(:member, :current) }
  let(:manager) { create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s]) }
  let!(:request) { ToolCheckoutRequest.create!(member: requester, tool: tool) }

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(Service::SlackConnector).to receive(:send_slack_message)
  end

  it "lets the shop resource manager decline with a reason and queues the requester notification" do
    described_class.decline!(request: request, actor: manager, reason: " Needs the safety class first ")

    expect(request.reload).to have_attributes(status: "declined", decided_by_id: manager.id,
                                              decision_reason: "Needs the safety class first")
    expect(request.decided_at).to be_present
    expect(CheckoutNotificationJob).to have_been_enqueued.with("decline", request.id.to_s)
  end

  it "records the decline in the audit log" do
    described_class.decline!(request: request, actor: manager, reason: "Needs the class first")

    entry = AuditLog.where(resource_id: request.id, event_type: "tool_checkout_request_declined").first
    expect(entry).to be_present
    expect(entry.actor_id).to eq(manager.id)
    expect(entry.subject_id).to eq(requester.id)
  end

  it "lets admin, board members and assigned approvers decline" do
    approver = create(:member, :current, member_contract_signed_date: Date.current)
    CheckoutApprover.create!(member: approver, tool_ids: [tool.id.to_s])
    [create(:member, :admin, :current), create(:member, :board_member, :current), approver].each do |actor|
      fresh = ToolCheckoutRequest.create!(member: create(:member, :current), tool: tool)

      described_class.decline!(request: fresh, actor: actor, reason: "No")

      expect(fresh.reload).to be_declined
    end
  end

  it "requires a reason of at most 255 characters" do
    expect { described_class.decline!(request: request, actor: manager, reason: "  ") }
      .to raise_error(Error::UnprocessableEntity, /reason is required/i)
    expect { described_class.decline!(request: request, actor: manager, reason: "x" * 256) }
      .to raise_error(Error::UnprocessableEntity, /at most 255/)
    expect(request.reload).to be_open
  end

  it "rejects the requester, unrelated members and approvers of other tools" do
    other_approver = create(:member, :current, member_contract_signed_date: Date.current)
    CheckoutApprover.create!(member: other_approver, tool_ids: [create(:tool).id.to_s])
    other_manager = create(:member, :resource_manager, :current, resource_manager_shop_ids: [create(:shop).id.to_s])
    [requester, create(:member, :current), other_approver, other_manager].each do |actor|
      expect { described_class.decline!(request: request, actor: actor, reason: "No") }
        .to raise_error(Error::Forbidden)
    end
    expect(request.reload).to be_open
  end

  it "cannot decline a request that is already resolved" do
    request.update!(status: "closed")

    expect { described_class.decline!(request: request, actor: manager, reason: "No") }
      .to raise_error(Error::UnprocessableEntity, /no longer open/)
  end

  it "does not let an approval follow a decline" do
    described_class.decline!(request: request, actor: manager, reason: "No")

    expect do
      CheckoutCreation.create!(actor_id: manager.id, member_id: requester.id, tool_id: tool.id,
                               shop_id: shop.id, source: "portal", request_id: request.id)
    end.to raise_error(Error::UnprocessableEntity)
    expect(ToolCheckout.where(member_id: requester.id, tool_id: tool.id).count).to eq(0)
  end

  it "lets the requester ask again after a decline" do
    described_class.decline!(request: request, actor: manager, reason: "No")

    expect(ToolCheckoutRequestEligibility.new(member: requester, tool: tool).error).to be_nil
  end
end
