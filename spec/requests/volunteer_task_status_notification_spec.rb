require 'rails_helper'

RSpec.describe 'Volunteer task status-edit reminders', type: :request do
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
    sign_in admin
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('production')
    allow(Service::SlackConnector).to receive(:enque_message)
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::SlackConnector).to receive(:update_slack_message).and_return({ 'ok' => true })
    allow(Service::ErrorReporter).to receive(:notify)
  end

  it 'reports a direct completed status honestly without issuing verification credits' do
    expect do
      put "/api/admin/volunteer_tasks/#{task.id}", params: { status: 'completed' }
    end.not_to change { VolunteerCredit.count }

    expect(response).to have_http_status(:ok)
    expect(task.reload.status).to eq('completed')
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      receipt.fetch('channel'), receipt.fetch('ts'),
      a_string_including("Task marked completed by #{admin.fullname}", 'no credits were issued by this edit', '6 days'),
      resolved_channel: true
    )
    expect(task.approval_notification['finalized']).to be(true)
  end

  it 'closes a reminder after a direct denied status edit' do
    put "/api/admin/volunteer_tasks/#{task.id}", params: { status: 'denied' }

    expect(response).to have_http_status(:ok)
    expect(task.reload.status).to eq('denied')
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      receipt.fetch('channel'), receipt.fetch('ts'),
      a_string_including("Denied by #{admin.fullname}", 'through a task status edit', '6 days'), resolved_channel: true
    )
    expect(task.approval_notification['closed_at']).to eq(now)
  end

  it 'ends the pending review when a status edit returns a task to claimed' do
    put "/api/admin/volunteer_tasks/#{task.id}", params: { status: 'claimed' }

    expect(response).to have_http_status(:ok)
    expect(task.reload.status).to eq('claimed')
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      receipt.fetch('channel'), receipt.fetch('ts'),
      a_string_including('Pending review ended', 'task status changed to claimed', '6 days'), resolved_channel: true
    )
    expect(task.approval_notification['finalized']).to be(true)
  end

  it 'keeps a failed direct cancellation update retryable without failing the status edit' do
    allow(Service::SlackConnector).to receive(:update_slack_message).and_raise(StandardError, 'Slack unavailable')

    put "/api/admin/volunteer_tasks/#{task.id}", params: { status: 'cancelled' }

    expect(response).to have_http_status(:ok)
    expect(task.reload.status).to eq('cancelled')
    expect(task.approval_notification['outcome']).to eq("Task cancelled by #{admin.fullname}")
    expect(task.approval_notification['finalized']).to be(false)
  end

  it 'leaves a pending reminder open when only the task title changes' do
    put "/api/admin/volunteer_tasks/#{task.id}", params: { title: 'Sort plywood' }

    expect(response).to have_http_status(:ok)
    expect(task.reload.title).to eq('Sort plywood')
    expect(task.status).to eq('pending')
    expect(task.approval_notification).to eq(receipt)
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end

  it 'does not close a reminder when status validation rejects the edit' do
    put "/api/admin/volunteer_tasks/#{task.id}", params: { status: 'invalid-status' }

    expect(response).not_to have_http_status(:ok)
    expect(task.reload.status).to eq('pending')
    expect(task.approval_notification).to eq(receipt)
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end

  it 'retains the linked bounty restriction on generic lifecycle edits' do
    ticket = create(:fix_ticket)
    task.update!(ticket_id: ticket.id)

    put "/api/admin/volunteer_tasks/#{task.id}", params: { status: 'cancelled' }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(task.reload.status).to eq('pending')
    expect(task.approval_notification).to eq(receipt)
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end
end
