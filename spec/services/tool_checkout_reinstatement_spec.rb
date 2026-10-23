require "rails_helper"

RSpec.describe ToolCheckoutReinstatement, requires_transactions: true do
  let(:admin) { create(:member, :current, :admin) }
  let(:member) { create(:member, :current) }
  let(:tool) { create(:tool) }
  let!(:revoked) do
    create(:tool_checkout, member: member, tool: tool, approved_by: admin).tap do |checkout|
      checkout.update!(revoked_at: 2.days.ago, revocation_reason: "Safety", revoked_by_id: admin.id)
    end
  end

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow_any_instance_of(ToolCheckout).to receive(:send_checkout_slack_notification)
    allow_any_instance_of(ToolCheckout).to receive(:invite_member_to_users_channel)
    allow_any_instance_of(ToolCheckout).to receive(:remove_member_from_users_channel)
    allow_any_instance_of(ToolCheckout).to receive(:send_revocation_slack_notification)
    allow(Service::ErrorReporter).to receive(:notify)
    allow(Service::SlackConnector).to receive(:send_slack_message)
  end

  def reinstate(actor: admin, reason: "Retrained")
    described_class.reinstate!(actor: actor, revoked_checkout: revoked, reason: reason)
  end

  it "keeps the revoked record intact and creates a linked active checkout" do
    checkout = reinstate

    expect(checkout).to be_active
    expect(checkout.reinstated_from_id).to eq(revoked.id)
    expect(checkout.approved_by_id).to eq(admin.id)
    expect(revoked.reload).to have_attributes(revocation_reason: "Safety")
    expect(revoked.revoked_at).to be_present
    expect(ToolCheckout.where(member_id: member.id, tool_id: tool.id).count).to eq(2)
  end

  it "records the reason, actor and time on the new checkout only" do
    checkout = reinstate(reason: "Completed retraining")

    expect(checkout.reload).to have_attributes(reinstatement_reason: "Completed retraining",
      reinstated_by_id: admin.id)
    expect(checkout.reinstated_at).to be_within(1.minute).of(Time.current)
    expect(revoked.reload).to have_attributes(reinstatement_reason: nil, reinstated_by_id: nil, reinstated_at: nil)
  end

  it "writes an audit entry with the actor and reason" do
    checkout = reinstate(reason: "Completed retraining")

    log = AuditLog.where(event_type: "tool_checkout_reinstated", resource_id: checkout.id).first
    expect(log.actor_id).to eq(admin.id)
    expect(log.after_snapshot).to include("reinstatement_reason" => "Completed retraining",
      "reinstated_from_id" => revoked.id.to_s)
  end

  it "notifies the member" do
    expect_any_instance_of(ToolCheckout).to receive(:send_checkout_slack_notification)
    reinstate
  end

  it "requires a reason" do
    expect { reinstate(reason: " ") }.to raise_error(Error::UnprocessableEntity, /reason/)
    expect(ToolCheckout.where(member_id: member.id, revoked_at: nil)).not_to exist
  end

  it "is limited to admins and board members" do
    rm = create(:member, :resource_manager, :current, resource_manager_shop_ids: [tool.shop_id.to_s])
    expect { reinstate(actor: rm) }.to raise_error(Error::Forbidden)
    expect(ToolCheckout.where(member_id: member.id, revoked_at: nil)).not_to exist
  end

  it "can reinstate only once" do
    reinstate
    expect { reinstate }.to raise_error(Error::UnprocessableEntity)
    expect(ToolCheckout.where(member_id: member.id, tool_id: tool.id).count).to eq(2)
  end

  it "rejects a checkout that is still active" do
    active = create(:tool_checkout)
    expect {
      described_class.reinstate!(actor: admin, revoked_checkout: active, reason: "x")
    }.to raise_error(Error::UnprocessableEntity, /not been revoked/)
  end

  it "rejects a member who is no longer eligible" do
    member.update!(status: "revoked")
    expect { reinstate }.to raise_error(Error::UnprocessableEntity)
  end

  it "does not let the member self-request while revoked" do
    expect(ToolCheckoutRequestEligibility.new(member: member, tool: tool).error)
      .to eq("A checkout record already exists for this tool")
  end

  it "lets a reinstated checkout stop a revoked record from blocking tool groups" do
    expect(ToolCheckout.blocking_revoked_tool_ids(member.id)).to eq([tool.id.to_s])
    reinstate
    expect(ToolCheckout.blocking_revoked_tool_ids(member.id)).to eq([])
  end
end
