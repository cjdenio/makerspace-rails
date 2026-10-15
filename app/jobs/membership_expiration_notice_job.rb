class MembershipExpirationNoticeJob < ApplicationJob
  queue_as :default

  def perform
    Service::MembershipExpirationNotice.run!
    SystemConfig.record_run('membership_expiration_notice', success: true)
  rescue => error
    SystemConfig.record_run('membership_expiration_notice', success: false)
    Service::ErrorReporter.notify('MembershipExpirationNoticeJob failed', context: { error: error.message })
    raise
  end
end
