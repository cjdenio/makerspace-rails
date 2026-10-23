require 'rails_helper'

RSpec.describe 'Volunteer task cancellation reminders', type: :model do
  let(:now) { Time.utc(2026, 10, 4, 12, 0, 0) }
  let(:admin) { create(:member, :admin, expirationTime: (now + 30.days).to_i * 1000) }
  let(:claimant) { create(:member, expirationTime: (now + 30.days).to_i * 1000) }
  let(:receipt) do
    {
      'ts' => '1727524800.000001', 'channel' => 'CADMIN_ORIGINAL',
      'destination_mode' => 'production', 'started_at' => now - 6.days,
      'subject' => "Task #42 for #{claimant.fullname}", 'finalized' => true
    }
  end
  let(:task) do
    VolunteerTask.create!(
      title: 'Sort lumber', description: 'Label the bins', created_by_id: admin.id,
      status: 'pending', claimed_by_id: claimant.id, completed_at: now - 6.days,
      approval_notification: receipt
    )
  end

  around { |example| travel_to(now) { example.run } }

  before do
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('production')
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::SlackConnector).to receive(:update_slack_message).and_return({ 'ok' => true })
    allow(Service::ErrorReporter).to receive(:notify)
  end

  it 'closes a cancelled task reminder even when its pending delivery was already finalized' do
    expect { task.cancel! }.not_to change { VolunteerCredit.count }

    expect(task.reload.status).to eq('cancelled')
    expect(task.approval_notification['outcome']).to eq('Task cancelled')
    expect(task.approval_notification['closed_at']).to eq(now)
    expect(task.approval_notification['finalized']).to be(true)
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      receipt.fetch('channel'), receipt.fetch('ts'),
      a_string_including('Task cancelled', 'Review closed after 6 days.'), resolved_channel: true
    )
  end

  it 'retains cancellation for a later in-place retry when Slack is unavailable' do
    allow(Service::SlackConnector).to receive(:update_slack_message).and_raise(StandardError, 'Slack unavailable')

    expect { task.cancel! }.not_to raise_error
    expect(task.reload.status).to eq('cancelled')
    expect(task.approval_notification['closed_at']).to eq(now)
    expect(task.approval_notification['finalized']).to be(false)

    allow(Service::SlackConnector).to receive(:update_slack_message).and_return({ 'ok' => true })
    travel 1.day
    Service::VolunteerApprovalReminder.remind!(task)

    expect(task.reload.approval_notification['finalized']).to be(true)
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      receipt.fetch('channel'), receipt.fetch('ts'),
      a_string_including('Task cancelled', 'Review closed after 6 days.'), resolved_channel: true
    ).twice
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'preserves an already closed approval message when the completed task is later cancelled' do
    approved = receipt.merge('outcome' => 'Approved earlier', 'closed_at' => now - 1.day)
    task.update!(status: 'completed', approval_notification: approved)

    task.cancel!

    expect(task.reload.status).to eq('cancelled')
    expect(task.approval_notification).to eq(approved)
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end

  it 'saves a cancellation snapshot without posting a new message when there is no receipt yet' do
    task.update!(approval_notification: {})

    task.cancel!

    notification = task.reload.approval_notification
    expect(notification['outcome']).to eq('Task cancelled')
    expect(notification['started_at']).to eq(now - 6.days)
    expect(notification['closed_at']).to eq(now)
    expect(notification['ts']).to be_nil
    expect(notification['finalized']).to be(true)
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end
end
