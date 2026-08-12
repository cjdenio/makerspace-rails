class MemberProvisioningReconciliationJob < ApplicationJob
  queue_as :default

  def perform
    Service::MemberProvisioning.reconcile_all!
  end
end
