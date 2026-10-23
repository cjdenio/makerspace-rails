require 'rails_helper'

RSpec.describe VolunteerEventReminderJob, type: :job do
  let(:now) { Time.zone.local(2026, 10, 4, 12) }
  let(:admin) { create(:member, :admin) }
  let(:member) { create(:member, status: 'activeMember') }

  around { |example| travel_to(now) { example.run } }

  before do
    allow(Service::SlackConnector).to receive(:admin_channel).and_return('configured-admin')
    allow(Service::SlackConnector).to receive(:send_slack_message)
      .and_return({ 'ts' => '123.456', 'channel' => 'CADMIN' })
    allow(Service::SlackConnector).to receive(:update_slack_message).and_return({ 'ok' => true })
    allow(Service::SlackConnector).to receive(:delete_slack_message)
    allow(Service::ErrorReporter).to receive(:notify)
    allow(SystemConfig).to receive(:record_run)
  end

  def pending_task(title: 'Sort lumber', completed_at: now - 6.days, **attributes)
    VolunteerTask.create!({
      title: title, description: 'Label the lumber bins', created_by_id: admin.id,
      status: 'pending', claimed_by_id: member.id, claimed_at: now - 30.days,
      completed_at: completed_at
    }.merge(attributes))
  end

  def open_event(title: 'Autumn Cleanup', event_date: now.to_date - 6, **attributes)
    VolunteerEvent.create!({
      title: title, credit_value: 1.0, created_by_id: admin.id,
      event_date: event_date, attendee_ids: [admin.id, member.id]
    }.merge(attributes))
  end

  it 'posts overdue tasks and one aggregate reminder per overdue event to the Admin Channel' do
    task = pending_task
    event = open_event

    described_class.perform_now

    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      a_string_including(task.title, task.display_number, member.fullname, '6 days'),
      'configured-admin'
    )
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      a_string_including(event.title, event.display_number, '6 days', '2 checked-in attendees'),
      'configured-admin'
    )
    expect(Service::SlackConnector).to have_received(:send_slack_message).exactly(2).times
    [task, event].each do |record|
      expect(record.reload.approval_notification).to include('ts' => '123.456', 'channel' => 'CADMIN')
    end
    expect(SystemConfig).to have_received(:record_run).with('volunteer_event_reminder', success: true)
  end

  it 'uses submission time, excludes unfinished claims, and requires strictly more than five elapsed days' do
    pending_task(title: 'Exactly five days', completed_at: now - 5.days)
    pending_task(title: 'Just submitted', completed_at: now - 1.hour)
    pending_task(title: 'No submission time', completed_at: nil)
    pending_task(title: 'Still doing work', completed_at: nil, status: 'claimed')
    pending_task(title: 'Already approved', status: 'completed')
    pending_task(title: 'Denied child', status: 'denied')

    described_class.perform_now

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'excludes undated, recent, future and already-closed events' do
    open_event(title: 'Exactly five calendar days', event_date: now.to_date - 5)
    open_event(title: 'Today', event_date: now.to_date)
    open_event(title: 'Future', event_date: now.to_date + 1)
    open_event(title: 'Undated', event_date: nil)
    open_event(title: 'Closed already', status: 'closed', closed_by_id: admin.id, closed_at: now)

    described_class.perform_now

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'updates the saved message in the original channel instead of posting a new reminder' do
    task = pending_task
    described_class.perform_now
    allow(Service::SlackConnector).to receive(:admin_channel).and_return('new-admin-setting')

    travel 1.day
    described_class.perform_now

    expect(Service::SlackConnector).to have_received(:send_slack_message).once
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CADMIN', '123.456', a_string_including(task.title, '7 days'), resolved_channel: true
    )
    expect(task.reload.approval_notification).to include('ts' => '123.456', 'channel' => 'CADMIN')
  end

  it 'keeps the existing receipt after an edit failure and does not post a replacement' do
    task = pending_task
    described_class.perform_now
    allow(Service::SlackConnector).to receive(:update_slack_message).and_raise(StandardError, 'Slack down')

    described_class.perform_now

    expect(Service::SlackConnector).to have_received(:send_slack_message).once
    expect(task.reload.approval_notification['ts']).to eq('123.456')
    expect(Service::ErrorReporter).to have_received(:notify).with(an_instance_of(StandardError))
  end

  it 'continues after a failed initial post and leaves that claim retryable' do
    failing_task = pending_task(title: 'Fails to notify')
    other_event = open_event(title: 'Second opportunity')
    allow(Service::SlackConnector).to receive(:send_slack_message)
      .with(a_string_including(failing_task.title), anything).and_raise(StandardError, 'Slack down')

    described_class.perform_now

    expect(failing_task.reload.approval_notification['ts']).to be_nil
    expect(other_event.reload.approval_notification['ts']).to eq('123.456')
    expect(Service::ErrorReporter).to have_received(:notify).with(an_instance_of(StandardError))
    expect(SystemConfig).to have_received(:record_run).with('volunteer_event_reminder', success: true)
  end

  it 'does not save a receipt when Slack omits the timestamp' do
    task = pending_task
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return({ 'channel' => 'CADMIN' })

    described_class.perform_now

    expect(task.reload.approval_notification['ts']).to be_nil
    expect(Service::ErrorReporter).to have_received(:notify)
  end

  it 'retries closed current receipts and archived denied claims without changing their closure duration' do
    final_receipt = {
      'ts' => 'closed.ts', 'channel' => 'CADMIN', 'subject' => 'Old reviewed claim',
      'started_at' => now - 9.days, 'closed_at' => now - 2.days,
      'outcome' => 'Approved by an approver', 'finalized' => false,
      'destination_mode' => Service::SlackConnector.message_destination_mode
    }
    closed_task = pending_task(status: 'completed', approval_notification: final_receipt)
    reused_task = pending_task(
      title: 'New claim still doing work', status: 'claimed', completed_at: nil,
      approval_notification_history: [final_receipt.merge('ts' => 'denied.ts', 'outcome' => 'Denied by an approver')]
    )
    closed_event = open_event(status: 'closed', approval_notification: final_receipt.merge('ts' => 'event.ts'))

    described_class.perform_now

    %w[closed.ts denied.ts event.ts].each do |ts|
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        'CADMIN', ts, a_string_including('Review closed after 7 days.'), resolved_channel: true
      )
    end
    expect(closed_task.reload.approval_notification['finalized']).to be(true)
    expect(reused_task.reload.approval_notification_history.first['finalized']).to be(true)
    expect(closed_event.reload.approval_notification['finalized']).to be(true)
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'records scan failures separately from individually rescued Slack failures' do
    allow(VolunteerTask).to receive(:any_of).and_raise(StandardError, 'Database unavailable')

    expect { described_class.perform_now }.to raise_error(StandardError, 'Database unavailable')

    expect(SystemConfig).to have_received(:record_run).with('volunteer_event_reminder', success: false)
    expect(Service::ErrorReporter).to have_received(:notify).with(an_instance_of(StandardError))
  end
end
