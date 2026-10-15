require "rails_helper"

RSpec.describe MemberProvisioningReconciliationJob, type: :job do
  before do
    allow(ToolCheckout).to receive(:recover_pending_revocation_cleanups!)
    allow(Service::MemberProvisioning).to receive(:reconcile_all!)
    allow(SystemConfig).to receive(:record_run)
  end

  it "runs the reconciliation sweep and records a successful automated-job run" do
    described_class.perform_now

    expect(ToolCheckout).to have_received(:recover_pending_revocation_cleanups!)
    expect(Service::MemberProvisioning).to have_received(:reconcile_all!)
    expect(SystemConfig).to have_received(:record_run)
      .with("member_provisioning_reconciliation", success: true)
  end

  it "records and reports a failed automated-job run" do
    error = StandardError.new("Mongo unavailable")
    allow(Service::MemberProvisioning).to receive(:reconcile_all!).and_raise(error)
    allow(Service::ErrorReporter).to receive(:notify)

    expect { described_class.perform_now }.to raise_error(error)

    expect(SystemConfig).to have_received(:record_run)
      .with("member_provisioning_reconciliation", success: false)
    expect(Service::ErrorReporter).to have_received(:notify).with(
      "MemberProvisioningReconciliationJob failed",
      context: { error: "Mongo unavailable" }
    )
  end
end
