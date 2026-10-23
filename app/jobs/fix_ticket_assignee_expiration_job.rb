class FixTicketAssigneeExpirationJob < ApplicationJob
  queue_as :default

  def perform
    Service::FixTicketAssigneeExpiration.run!
    SystemConfig.record_run('fix_ticket_assignee_expiration', success: true)
  rescue => error
    SystemConfig.record_run('fix_ticket_assignee_expiration', success: false)
    Service::ErrorReporter.notify('FixTicketAssigneeExpirationJob failed', context: { error: error.message })
    raise
  end
end
