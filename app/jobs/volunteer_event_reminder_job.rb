class VolunteerEventReminderJob < ApplicationJob
  queue_as :default

  def perform
    now = Time.current
    VolunteerTask.where(status: 'pending', :completed_at.ne => nil, :shop_id.ne => nil).each do |task|
      VolunteerApproverNotification.notify!(task, now: now)
    end
    VolunteerEvent.where(status: 'open', :event_date.lt => now.in_time_zone.to_date, :shop_id.ne => nil).each do |event|
      VolunteerApproverNotification.notify!(event, now: now)
    end
    reminder_tasks(now).each { |task| Service::VolunteerApprovalReminder.remind!(task, now: now) }
    reminder_events(now).each { |event| Service::VolunteerApprovalReminder.remind!(event, now: now) }
    # Keep unindexed receipt retries out of the indexed status/date scans.
    # A record selected by both scans only refreshes its pending message once.
    [VolunteerTask, VolunteerEvent].each do |model|
      retry_notifications(model).each { |record| Service::VolunteerApprovalReminder.sync_closed!(record) }
    end
    SystemConfig.record_run('volunteer_event_reminder', success: true)
  rescue => e
    SystemConfig.record_run('volunteer_event_reminder', success: false)
    Service::ErrorReporter.notify(e)
    raise
  end

  private

  def reminder_tasks(now)
    VolunteerTask.where(
      status: 'pending', completed_at: { '$ne' => nil, '$lt' => now - Service::VolunteerApprovalReminder::WAIT_DAYS.days }
    )
  end

  def reminder_events(now)
    VolunteerEvent.where(
      status: 'open', event_date: { '$ne' => nil, '$lt' => now.to_date - Service::VolunteerApprovalReminder::WAIT_DAYS }
    )
  end

  def retry_notifications(model)
    model.any_of(
      { 'approval_notification.finalized' => false },
      { approval_notification_history: { '$elemMatch' => { 'finalized' => false } } }
    )
  end
end
