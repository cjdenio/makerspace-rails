class MemberProvisioningJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(member_id)
    member = Member.find_by(id: member_id)
    return if member.nil?

    Service::MemberProvisioning.provision(member)
  end
end
