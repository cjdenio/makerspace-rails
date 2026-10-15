require "rails_helper"

RSpec.describe ToolCheckout do
  it "does not rerun revocation cleanup when only the reason changes" do
    checkout = create(:tool_checkout, revoked_at: Time.current)
    allow(CheckoutApproverVolunteering).to receive(:revoke_for!)
    allow(CheckoutApproverCredit).to receive(:reverse!)

    checkout.update!(revocation_reason: "Corrected reason")

    expect(CheckoutApproverVolunteering).not_to have_received(:revoke_for!)
    expect(CheckoutApproverCredit).not_to have_received(:reverse!)
  end

  it "preserves a durable pending cleanup marker when synchronous cleanup fails" do
    checkout = create(:tool_checkout)
    allow(CheckoutApproverVolunteering).to receive(:revoke_for!)
      .and_raise(Error::UnprocessableEntity.new("busy"))

    expect {
      checkout.update!(revoked_at: Time.current)
    }.to raise_error(Error::UnprocessableEntity, "busy")

    expect(checkout.reload.revoked_at).to be_present
    expect(checkout).to be_revocation_cleanup_pending
  end

  it "marks cleanup pending as part of the revocation update before cleanup starts" do
    checkout = create(:tool_checkout)
    allow(CheckoutApproverVolunteering).to receive(:revoke_for!) do
      persisted = ToolCheckout.find(checkout.id)
      expect(persisted.revoked_at).to be_present
      expect(persisted).to be_revocation_cleanup_pending
      raise Error::UnprocessableEntity.new("busy")
    end

    expect { checkout.update!(revoked_at: Time.current) }
      .to raise_error(Error::UnprocessableEntity, "busy")
  end

  it "resumes partial cleanup on a later update and clears the pending marker" do
    checkout = create(:tool_checkout)
    calls = 0
    allow(CheckoutApproverVolunteering).to receive(:revoke_for!) do
      calls += 1
      raise Error::UnprocessableEntity.new("busy") if calls == 1
    end
    allow(CheckoutApproverCredit).to receive(:reverse!)

    expect { checkout.update!(revoked_at: Time.current) }
      .to raise_error(Error::UnprocessableEntity, "busy")

    expect {
      checkout.reload.update!(revocation_reason: "Retry cleanup")
    }.to have_enqueued_job(ToolCheckoutSlackCanvasSyncJob).with(
      checkout.tool.shop_id.to_s, checkout.id.to_s, "remove"
    )
    expect(checkout.reload).not_to be_revocation_cleanup_pending
    expect(CheckoutApproverCredit).to have_received(:reverse!).with(checkout)
  end

  it "automatically sweeps durable pending cleanup without another checkout update" do
    checkout = create(:tool_checkout, revoked_at: Time.current, revocation_cleanup_pending: true)
    allow(CheckoutApproverVolunteering).to receive(:revoke_for!)
    allow(CheckoutApproverCredit).to receive(:reverse!)

    expect {
      described_class.recover_pending_revocation_cleanups!
    }.to have_enqueued_job(ToolCheckoutSlackCanvasSyncJob).with(
      checkout.tool.shop_id.to_s, checkout.id.to_s, "remove"
    )

    expect(checkout.reload).not_to be_revocation_cleanup_pending
  end

  it "recovers durable controller revocation side effects before clearing the marker" do
    actor = create(:member, :admin, :current)
    checkout = create(:tool_checkout, revoked_at: Time.current, revocation_reason: "Unsafe use",
      revoked_by_id: actor.id, revocation_cleanup_pending: true)
    allow(CheckoutApproverVolunteering).to receive(:revoke_for!)
    allow(CheckoutApproverCredit).to receive(:reverse!)
    allow(checkout).to receive(:send_revocation_slack_notification)
    allow(checkout).to receive(:send_approver_revocation_slack_notification)
    allow(checkout).to receive(:remove_member_from_users_channel)

    checkout.retry_revocation_cleanup!

    expect(checkout).to have_received(:send_revocation_slack_notification)
    expect(checkout).to have_received(:send_approver_revocation_slack_notification).with(actor)
    expect(checkout).to have_received(:remove_member_from_users_channel)
    expect(AuditLog.where(event_type: "tool_checkout_revoked", resource_id: checkout.id)).to exist
    expect(checkout.reload.revocation_cleanup_completed_steps).to contain_exactly(
      "member_notified", "approver_notified", "users_channel_removed", "audit_logged"
    )
    expect(checkout).not_to be_revocation_cleanup_pending
  end
end
