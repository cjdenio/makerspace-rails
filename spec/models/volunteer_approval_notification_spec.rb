require 'rails_helper'

RSpec.describe 'Volunteer approval reminder lifecycle', type: :model do
  let(:now) { Time.utc(2026, 10, 4, 12, 0, 0) }
  let(:admin) { create(:member, :admin, expirationTime: (now + 30.days).to_i * 1000) }
  let(:member) { create(:member, expirationTime: (now + 30.days).to_i * 1000) }
  let(:receipt) do
    {
      'ts' => '1727524800.000001',
      'channel' => 'CADMIN_ORIGINAL',
      'destination_mode' => 'production',
      'started_at' => now - 6.days,
      'subject' => "Task #42: Sort lumber, claimed by #{member.fullname}",
      'finalized' => false
    }
  end
  let(:task) do
    VolunteerTask.create!(
      title: 'Sort lumber', description: 'Label the bins', created_by_id: admin.id,
      status: 'pending', claimed_by_id: member.id, claimed_at: now - 8.days,
      completed_at: now - 6.days, approval_notification: receipt
    )
  end

  around { |example| travel_to(now) { example.run } }

  before do
    allow(SlackUser).to receive(:find_by).and_return(nil)
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('production')
    allow(Service::SlackConnector).to receive(:update_slack_message).and_return({ 'ok' => true })
    allow(Service::ErrorReporter).to receive(:notify)
    allow_any_instance_of(VolunteerCredit).to receive(:check_discount_threshold!)
  end

  it 'updates the original message on approval with the review duration and issues the credit' do
    expect { task.complete!(admin) }.to change { VolunteerCredit.count }.by(1)

    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      receipt.fetch('channel'), receipt.fetch('ts'),
      a_string_including("Approved by #{admin.fullname}", '6 days'), resolved_channel: true
    )
    notification = task.reload.approval_notification
    expect(task.status).to eq('completed')
    expect(notification['started_at']).to eq(now - 6.days)
    expect(notification['closed_at']).to eq(now)
    expect(notification['finalized']).to be(true)
  end

  it 'reloads a controller-held task so a newly posted receipt is finalized on approval' do
    task.update!(approval_notification: {})
    controller_task = VolunteerTask.find(task.id)
    task.set(approval_notification: receipt)

    controller_task.complete!(admin)

    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      receipt.fetch('channel'), receipt.fetch('ts'),
      a_string_including('Approved', 'Review closed after 6 days.'), resolved_channel: true
    )
    expect(controller_task.reload.approval_notification['finalized']).to be(true)
  end

  it 'preserves the original claim snapshot when rejection clears the ordinary task claimant' do
    task.reject_pending!(admin, 'Missing labels')

    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      receipt.fetch('channel'), receipt.fetch('ts'),
      a_string_including(member.fullname, "Denied by #{admin.fullname}", 'Missing labels', '6 days'), resolved_channel: true
    )
    notification = task.reload.approval_notification
    expect(task.status).to eq('available')
    expect(task.claimed_by_id).to be_nil
    expect(task.completed_at).to be_nil
    expect(notification['subject']).to eq(receipt.fetch('subject'))
    expect(notification['closed_at']).to eq(now)
    expect(notification['finalized']).to be(true)
  end

  it 'keeps approval and its credit durable when the final Slack update fails' do
    allow(Service::SlackConnector).to receive(:update_slack_message).and_raise(StandardError, 'Slack unavailable')

    expect { task.complete!(admin) }.to change { VolunteerCredit.count }.by(1)

    notification = task.reload.approval_notification
    expect(task.status).to eq('completed')
    expect(notification['outcome']).to eq("Approved by #{admin.fullname}")
    expect(notification['closed_at']).to eq(now)
    expect(notification['finalized']).to be(false)

    allow(Service::SlackConnector).to receive(:update_slack_message).and_return({ 'ok' => true })
    travel 1.day
    Service::VolunteerApprovalReminder.sync_closed!(task)

    expect(task.reload.approval_notification['finalized']).to be(true)
    expect(VolunteerCredit.where(task_id: task.id).count).to eq(1)
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      receipt.fetch('channel'), receipt.fetch('ts'),
      a_string_including('Approved', 'Review closed after 6 days.'), resolved_channel: true
    ).twice
  end

  it 'issues the task credit before a notification metadata write failure and refuses duplicate approval' do
    allow(Service::VolunteerApprovalReminder).to receive(:write_notification)
      .and_raise(StandardError, 'Notification metadata storage unavailable')

    expect { task.complete!(admin) }.to raise_error(StandardError, 'Notification metadata storage unavailable')

    expect(task.reload.status).to eq('completed')
    expect(task.approval_notification).to include('closed_at' => now, 'finalized' => false)
    expect(task.approval_notification['outcome']).to include('Credit award not confirmed', 'correct the award manually')
    expect(VolunteerEventReminderJob.new.send(:retry_notifications, VolunteerTask).where(id: task.id)).to exist
    expect(VolunteerCredit.where(task_id: task.id, member_id: member.id, status: 'approved').count).to eq(1)
    expect(Service::ErrorReporter).to have_received(:notify).with(an_instance_of(StandardError))
    expect { task.complete!(admin) }.to raise_error(Error::Forbidden)
    expect(VolunteerCredit.where(task_id: task.id).count).to eq(1)

    allow(Service::VolunteerApprovalReminder).to receive(:write_notification).and_call_original
    Service::VolunteerApprovalReminder.sync_closed!(task)

    expect(task.reload.approval_notification['finalized']).to be(true)
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      receipt.fetch('channel'), receipt.fetch('ts'),
      a_string_including('Credit award not confirmed', 'correct the award manually', 'Review closed after 6 days.'),
      resolved_channel: true
    ).once
    expect(VolunteerCredit.where(task_id: task.id).count).to eq(1)
  end

  it 'saves the final outcome when membership discount evaluation fails after credit issuance' do
    allow_any_instance_of(VolunteerCredit).to receive(:check_discount_threshold!)
      .and_raise(StandardError, 'Discount evaluation unavailable')

    expect { task.complete!(admin) }.to raise_error(StandardError, 'Discount evaluation unavailable')

    expect(task.reload.status).to eq('completed')
    expect(VolunteerCredit.where(task_id: task.id, member_id: member.id, status: 'approved').count).to eq(1)
    expect(task.approval_notification['outcome']).to eq("Approved by #{admin.fullname}")
    expect(task.approval_notification['finalized']).to be(true)
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      receipt.fetch('channel'), receipt.fetch('ts'),
      a_string_including('Approved', 'Review closed after 6 days.'), resolved_channel: true
    )
  end

  context 'when the task credit cannot be created' do
    let(:credit_error) { StandardError.new('Credit storage unavailable') }
    let(:failure_outcome) do
      "Credit award failed during approval by #{admin.fullname}; " \
        'verify whether a credit was saved and correct the award manually'
    end

    before do
      allow(VolunteerCredit).to receive(:create!).and_raise(credit_error)
    end

    it 'records an actionable failure instead of approved success and refuses duplicate approval' do
      expect { task.complete!(admin) }.to raise_error { |error| expect(error).to equal(credit_error) }

      notification = task.reload.approval_notification
      expect(task.status).to eq('completed')
      expect(VolunteerCredit.where(task_id: task.id).count).to eq(0)
      expect(notification).to include(
        'outcome' => failure_outcome, 'started_at' => now - 6.days,
        'closed_at' => now, 'finalized' => true
      )
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        receipt.fetch('channel'), receipt.fetch('ts'),
        a_string_starting_with('⚠️').and(a_string_including(failure_outcome, 'Review closed after 6 days.')),
        resolved_channel: true
      )
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
      expect { task.complete!(admin) }.to raise_error(Error::Forbidden)
      expect(VolunteerCredit).to have_received(:create!).once
    end

    it 'leaves a failed Slack update retryable by the daily job without recreating the credit' do
      task.update!(approval_notification: receipt.merge('finalized' => true))
      allow(Service::SlackConnector).to receive(:update_slack_message).and_raise(StandardError, 'Slack unavailable')
      allow(SystemConfig).to receive(:record_run)

      expect { task.complete!(admin) }.to raise_error { |error| expect(error).to equal(credit_error) }

      notification = task.reload.approval_notification
      expect(notification).to include('outcome' => failure_outcome, 'closed_at' => now, 'finalized' => false)
      allow(Service::SlackConnector).to receive(:update_slack_message).and_return({ 'ok' => true })
      travel 1.day
      VolunteerEventReminderJob.perform_now

      expect(task.reload.approval_notification['finalized']).to be(true)
      expect(task.approval_notification['outcome']).to eq(failure_outcome)
      expect(VolunteerCredit.where(task_id: task.id).count).to eq(0)
      expect(VolunteerCredit).to have_received(:create!).once
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        receipt.fetch('channel'), receipt.fetch('ts'),
        a_string_including(failure_outcome, 'Review closed after 6 days.'), resolved_channel: true
      ).twice
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end

    it 'preserves the credit creation error when recording its failure outcome also fails' do
      metadata_error = StandardError.new('Notification metadata storage unavailable')
      allow(Service::VolunteerApprovalReminder).to receive(:write_notification).and_raise(metadata_error)

      expect { task.complete!(admin) }.to raise_error { |error| expect(error).to equal(credit_error) }

      expect(task.reload.status).to eq('completed')
      expect(VolunteerCredit.where(task_id: task.id).count).to eq(0)
      expect(task.approval_notification).to include('closed_at' => now, 'finalized' => false)
      expect(task.approval_notification['outcome']).to include('Credit award not confirmed', 'correct the award manually')
      expect(VolunteerEventReminderJob.new.send(:retry_notifications, VolunteerTask).where(id: task.id)).to exist
      expect(Service::SlackConnector).not_to have_received(:update_slack_message)
      expect(Service::ErrorReporter).to have_received(:notify).with(metadata_error)
      expect { task.complete!(admin) }.to raise_error(Error::Forbidden)
    end

    it 'records the failure without posting a new message when there is no overdue receipt' do
      task.update!(approval_notification: {})

      expect { task.complete!(admin) }.to raise_error { |error| expect(error).to equal(credit_error) }

      expect(task.reload.approval_notification).to include(
        'outcome' => failure_outcome, 'closed_at' => now, 'finalized' => true
      )
      expect(task.approval_notification['ts']).to be_nil
      expect(VolunteerCredit.where(task_id: task.id).count).to eq(0)
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
      expect(Service::SlackConnector).not_to have_received(:update_slack_message)
    end

    it 'flags an ambiguous save failure for manual review without creating a second award' do
      allow(VolunteerCredit).to receive(:create!).and_wrap_original do |original, *arguments, **options|
        original.call(*arguments, **options)
        raise credit_error
      end

      expect { task.complete!(admin) }.to raise_error { |error| expect(error).to equal(credit_error) }

      expect(task.reload.status).to eq('completed')
      expect(VolunteerCredit.where(task_id: task.id, member_id: member.id, status: 'approved').count).to eq(1)
      expect(task.approval_notification['outcome']).to eq(failure_outcome)
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        receipt.fetch('channel'), receipt.fetch('ts'),
        a_string_starting_with('⚠️').and(a_string_including(failure_outcome)), resolved_channel: true
      )
      expect { task.complete!(admin) }.to raise_error(Error::Forbidden)
      expect(VolunteerCredit).to have_received(:create!).once
      expect(VolunteerCredit.where(task_id: task.id).count).to eq(1)
    end
  end

  it 'retains a failed final update through reclaiming and resubmission for later retry' do
    allow(Service::SlackConnector).to receive(:update_slack_message).and_raise(StandardError, 'Slack unavailable')
    expect { task.reject_pending!(admin, 'Missing labels') }.not_to raise_error
    expect(task.reload.approval_notification['finalized']).to be(false)

    task.claim!(member)
    task.mark_pending!(member)

    expect(task.reload.approval_notification).to be_empty
    expect(task.approval_notification_history.length).to eq(1)
    old_claim = task.approval_notification_history.first
    expect(old_claim['ts']).to eq(receipt.fetch('ts'))
    expect(old_claim['closed_at']).to eq(now)
    expect(task.completed_at).to eq(now)

    allow(Service::SlackConnector).to receive(:update_slack_message).and_return({ 'ok' => true })
    travel 1.day
    Service::VolunteerApprovalReminder.sync_closed!(task)

    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      receipt.fetch('channel'), receipt.fetch('ts'),
      a_string_including('Denied', '6 days'), resolved_channel: true
    ).twice
    expect(task.reload.approval_notification_history.first['finalized']).to be(true)
    expect(task.approval_notification).to be_empty
    expect(task.status).to eq('pending')
  end

  it 'archives an earlier receipt when a claimed task is resubmitted' do
    task.update!(status: 'claimed', approval_notification: receipt.merge(
      'outcome' => 'Denied earlier', 'closed_at' => now - 1.day, 'finalized' => true
    ))

    task.mark_pending!(member)

    expect(task.reload.approval_notification).to be_empty
    expect(task.approval_notification_history.first['ts']).to eq(receipt.fetch('ts'))
    expect(task.completed_at).to eq(now)
  end

  it 'finalizes a denied recurring child without changing its parent' do
    parent = VolunteerTask.create!(
      title: 'Sort lumber', description: 'Label the bins', created_by_id: admin.id,
      status: 'recurring', days: 7, next_available: Date.current + 1
    )
    task.update!(parent_task_id: parent.id)

    task.reject_pending!(admin, 'Missing labels')

    expect(task.reload.status).to eq('denied')
    expect(task.claimed_by_id).to eq(member.id)
    expect(task.approval_notification['finalized']).to be(true)
    expect(parent.reload.status).to eq('recurring')
    expect(parent.next_available).to eq(Date.current + 1)
  end

  it 'delivers linked bounty rejection only after its transaction block finishes' do
    ticket = create(:fix_ticket, bounty_assignee_ids: [member.id], assignee_ids: [member.id])
    task.update!(ticket_id: ticket.id)
    inside_transaction = false
    allow(FixTicketService).to receive(:transaction) do |_, &block|
      inside_transaction = true
      block.call
      inside_transaction = false
    end
    allow(FixTicketService).to receive(:assignment_event!)
    allow(FixTicketService).to receive(:enqueue)
    expect(Service::SlackConnector).to receive(:update_slack_message) do |channel, ts, text, **options|
      expect(inside_transaction).to be(false)
      expect(channel).to eq(receipt.fetch('channel'))
      expect(ts).to eq(receipt.fetch('ts'))
      expect(options).to eq(resolved_channel: true)
      expect(text).to include('Denied', 'Missing labels', '6 days')
    end

    task.reject_pending!(admin, 'Missing labels')

    expect(task.reload.approval_notification['finalized']).to be(true)
    expect(ticket.reload.bounty_assignee_ids).not_to include(member.id)
  end

  it 'does not finalize or alter the receipt when self-review is refused' do
    expect { task.complete!(member) }.to raise_error(Error::Forbidden)
    expect { task.reject_pending!(member, 'Reject myself') }.to raise_error(Error::Forbidden)

    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
    expect(task.reload.approval_notification).to eq(receipt)
    expect(task.status).to eq('pending')
  end

  it 'updates an event receipt with an actionable warning when an attendee award fails' do
    event = VolunteerEvent.create!(
      title: 'Cleanup', created_by_id: admin.id, event_date: Date.current - 6,
      attendee_ids: [member.id], approval_notification: receipt.merge('subject' => 'Event E3: Cleanup')
    )
    allow(VolunteerCredit).to receive(:create!).and_raise(StandardError, 'Credit storage unavailable')

    expect { event.close!(admin) }.not_to raise_error

    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      receipt.fetch('channel'), receipt.fetch('ts'),
      a_string_including('⚠️', 'Credit award failed', member.id.to_s, 'credit creation', '6 days'), resolved_channel: true
    )
    expect(event.reload.status).to eq('closed')
    expect(event.approval_notification['closed_at']).to eq(event.closed_at)
    expect(event.approval_notification['finalized']).to be(true)
    expect(Service::ErrorReporter).to have_received(:notify).with(an_instance_of(StandardError))
  end

  it 'keeps event closure and attendance credits durable when saving final delivery fails' do
    event = VolunteerEvent.create!(
      title: 'Cleanup', created_by_id: admin.id, event_date: Date.current - 6,
      attendee_ids: [member.id, admin.id], approval_notification: receipt.merge('subject' => 'Event E3: Cleanup')
    )
    allow(Service::VolunteerApprovalReminder).to receive(:write_notification)
      .and_raise(StandardError, 'Notification metadata storage unavailable')

    expect { event.close!(admin) }.to raise_error(StandardError, 'Notification metadata storage unavailable')

    expect(event.reload.status).to eq('closed')
    expect(event.approval_notification).to include(
      'closed_at' => event.closed_at, 'finalized' => false
    )
    expect(event.approval_notification['outcome']).to start_with('Credit award not confirmed')
    expect(VolunteerEventReminderJob.new.send(:retry_notifications, VolunteerEvent).where(id: event.id)).to exist
    credits = VolunteerCredit.where(description: "Attended event: Cleanup (#{event.display_number})", status: 'approved')
    expect(credits.pluck(:member_id)).to contain_exactly(member.id, admin.id)
    expect(Service::ErrorReporter).to have_received(:notify).with(an_instance_of(StandardError)).at_least(:once)
    expect { event.close!(admin) }.to raise_error(Error::Forbidden)
    expect(credits.count).to eq(2)

    allow(Service::VolunteerApprovalReminder).to receive(:write_notification).and_call_original
    Service::VolunteerApprovalReminder.sync_closed!(event)

    expect(event.reload.approval_notification['finalized']).to be(true)
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      receipt.fetch('channel'), receipt.fetch('ts'),
      a_string_including('⚠️', 'Credit award not confirmed', 'Review closed after 6 days.'), resolved_channel: true
    ).twice
    expect(credits.count).to eq(2)
  end

  it 'finalizes a pending task reminder before destroying the task' do
    pending_task = task
    task_id = pending_task.id

    pending_task.destroy

    expect(VolunteerTask.where(id: task_id)).not_to exist
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      receipt.fetch('channel'), receipt.fetch('ts'),
      a_string_including('Task deletion requested', '6 days'), resolved_channel: true
    )
  end

  it 'preserves the task and retries its final reminder when deletion cannot finish delivery' do
    pending_task = task
    allow(Service::SlackConnector).to receive(:update_slack_message).and_raise('Slack unavailable')

    expect { pending_task.destroy }.to raise_error(/Cannot delete task until its Slack reminders/)

    expect(VolunteerTask.where(id: pending_task.id)).to exist
    expect(pending_task.reload.status).to eq('cancelled')
    expect(pending_task.approval_notification['finalized']).to be(false)
    expect(VolunteerEventReminderJob.new.send(:retry_notifications, VolunteerTask).where(id: pending_task.id)).to exist
    allow(Service::SlackConnector).to receive(:update_slack_message).and_return('ok' => true)
    pending_task.destroy
    expect(VolunteerTask.where(id: pending_task.id)).not_to exist
  end

  context 'when rescheduling an open event with a channel reminder' do
    let(:event) do
      VolunteerEvent.create!(title: 'Cleanup', created_by_id: admin.id, event_date: Date.current - 6,
        attendee_ids: [member.id], approval_notification: receipt.merge(
          'started_at' => (Date.current - 6).in_time_zone.beginning_of_day.to_time.getutc,
          'subject' => 'Event E3: Cleanup', 'finalized' => true
        ))
    end
    let(:new_date) { Date.current + 10 }

    before { allow(Service::SlackConnector).to receive(:delete_slack_message) }

    it 'finalizes the old message and posts a fresh reminder with the rescheduled activity date' do
      old_start = event.approval_notification.fetch('started_at')
      scheduled_date = new_date

      event.update!(event_date: scheduled_date)

      expect(event.reload.approval_notification).to be_empty
      expect(event.approval_notification_history).to contain_exactly(hash_including(
        'ts' => receipt.fetch('ts'), 'channel' => receipt.fetch('channel'), 'started_at' => old_start,
        'closed_at' => now, 'outcome' => a_string_including('Rescheduled'), 'finalized' => true
      ))
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        receipt.fetch('channel'), receipt.fetch('ts'), a_string_including('Rescheduled', '6 days'), resolved_channel: true
      ).once
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)

      allow(Service::SlackConnector).to receive(:send_slack_message).and_return('ts' => 'NEW', 'channel' => 'CNEW')
      travel_to((scheduled_date + 6).in_time_zone.change(hour: 12))
      Service::VolunteerApprovalReminder.remind!(event)

      expect(event.reload.approval_notification).to include(
        'ts' => 'NEW', 'channel' => 'CNEW', 'started_at' => scheduled_date.in_time_zone.beginning_of_day.to_time.getutc
      )
      expect(event.approval_notification_history.first['ts']).to eq(receipt.fetch('ts'))
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        a_string_including(scheduled_date.strftime('%m/%d/%Y'), '6 days'), Service::SlackConnector.admin_channel
      ).once
    end

    it 'keeps a failed reschedule update selectable by the daily job and retries the original message' do
      allow(Service::SlackConnector).to receive(:update_slack_message).and_raise('Slack unavailable')
      allow(SystemConfig).to receive(:record_run)

      expect { event.update!(event_date: new_date) }.not_to raise_error

      expect(event.reload.approval_notification).to be_empty
      expect(event.approval_notification_history.first).to include(
        'ts' => receipt.fetch('ts'), 'closed_at' => now, 'finalized' => false
      )
      expect(VolunteerEventReminderJob.new.send(:retry_notifications, VolunteerEvent).where(id: event.id)).to exist

      allow(Service::SlackConnector).to receive(:update_slack_message).and_return('ok' => true)
      travel 1.day
      VolunteerEventReminderJob.perform_now

      expect(event.reload.approval_notification_history.first['finalized']).to be(true)
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        receipt.fetch('channel'), receipt.fetch('ts'), a_string_including('Rescheduled', '6 days'), resolved_channel: true
      ).twice
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end

    it 'attaches an in-flight reminder post to the old schedule after the event date changes' do
      event.update!(approval_notification: {})
      old_start = event.event_date.in_time_zone.beginning_of_day.to_time.getutc
      allow(Service::SlackConnector).to receive(:send_slack_message) do
        event.update!(event_date: new_date)
        { 'ts' => 'INFLIGHT', 'channel' => 'COLD' }
      end

      Service::VolunteerApprovalReminder.remind!(event)

      expect(event.reload.approval_notification).to be_empty
      expect(event.approval_notification_history).to contain_exactly(hash_including(
        'ts' => 'INFLIGHT', 'channel' => 'COLD', 'started_at' => old_start,
        'closed_at' => now, 'outcome' => a_string_including('Rescheduled'), 'finalized' => true
      ))
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        'COLD', 'INFLIGHT', a_string_including('Rescheduled', '6 days'), resolved_channel: true
      ).once
      expect(Service::SlackConnector).not_to have_received(:delete_slack_message)
    end

    it 'retains the old date and receipt when validation rejects the date edit' do
      old_date = event.event_date
      original_receipt = event.approval_notification.deep_dup

      expect { event.update!(title: '', event_date: new_date) }.to raise_error(Mongoid::Errors::Validations)

      expect(event.reload.event_date).to eq(old_date)
      expect(event.approval_notification).to eq(original_receipt)
      expect(event.approval_notification_history).to be_empty
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
      expect(Service::SlackConnector).not_to have_received(:update_slack_message)
    end
  end
end
