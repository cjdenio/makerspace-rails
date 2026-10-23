class MemberProvisioningReconciliationJob < ApplicationJob
  queue_as :default

  def perform
    ToolCheckout.recover_pending_revocation_cleanups!
    Service::MemberProvisioning.reconcile_all!
    SystemConfig.record_run("member_provisioning_reconciliation", success: true)
  rescue => error
    SystemConfig.record_run("member_provisioning_reconciliation", success: false)
    Service::ErrorReporter.notify(
      "MemberProvisioningReconciliationJob failed",
      context: { error: error.message }
    )
    raise error
  end
end
