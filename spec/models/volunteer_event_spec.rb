require 'rails_helper'

describe VolunteerEvent, type: :model do
  let(:organizer) { create(:member, :admin, status: 'activeMember') }
  let(:attendee)  { create(:member, status: 'activeMember') }

  before do
    allow(SlackUser).to receive(:find_by).and_return(nil)
    allow(Service::SlackConnector).to receive(:enque_message)
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(EarnedMembership).to receive_message_chain(:active, :where, :exists?).and_return(false)
    allow(Service::ErrorReporter).to receive(:notify)
  end

  describe '#close!' do
    it 'issues attendance credit to every attendee, including the organizer closing their own event' do
      event = VolunteerEvent.create!(
        title: 'January Cleanup',
        event_date: Date.today,
        created_by_id: organizer.id,
        attendee_ids: [organizer.id, attendee.id]
      )

      event.close!(organizer)

      expect(VolunteerCredit.where(member_id: organizer.id, issued_by_id: organizer.id, status: 'approved')).to exist
      expect(VolunteerCredit.where(member_id: attendee.id, issued_by_id: organizer.id, status: 'approved')).to exist
    end

    it 'persists its closure with a retryable reminder even when the final Slack update fails' do
      event = VolunteerEvent.create!(title: 'Overdue Cleanup', event_date: Date.today - 6,
        created_by_id: organizer.id, attendee_ids: [attendee.id], approval_notification: {
          'ts' => '123.456', 'channel' => 'CREVIEW', 'destination_mode' => 'production',
          'started_at' => (Date.today - 6).in_time_zone.beginning_of_day.to_time.getutc,
          'subject' => 'Overdue Cleanup', 'finalized' => true
        })
      allow(Service::VolunteerApprovalReminder).to receive(:record_outcome!).and_call_original
      allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('production')
      allow(Service::SlackConnector).to receive(:update_slack_message).and_raise('Slack unavailable')

      expect { event.close!(organizer) }.not_to raise_error

      expect(event.reload.status).to eq('closed')
      expect(event.approval_notification).to include(
        'ts' => '123.456', 'channel' => 'CREVIEW', 'outcome' => "Event closed by #{organizer.fullname}",
        'closed_at' => event.closed_at, 'finalized' => false
      )
      expect(Service::VolunteerApprovalReminder).to have_received(:record_outcome!).with(
        event, hash_including('outcome' => "Event closed by #{organizer.fullname}"), expected_status: 'closed'
      ).once
      expect(VolunteerCredit.where(member_id: attendee.id, issued_by_id: organizer.id, status: 'approved')).to exist
      expect(VolunteerEventReminderJob.new.send(:retry_notifications, VolunteerEvent).where(id: event.id)).to exist
    end

    it 'preserves the unconfirmed warning and saved credit when the final outcome write fails' do
      event = VolunteerEvent.create!(title: 'Overdue Cleanup', event_date: Date.today - 6,
        created_by_id: organizer.id, attendee_ids: [attendee.id], approval_notification: {
          'ts' => '123.456', 'channel' => 'CREVIEW', 'destination_mode' => 'production',
          'started_at' => (Date.today - 6).in_time_zone.beginning_of_day.to_time.getutc,
          'subject' => 'Overdue Cleanup', 'finalized' => true
        })
      allow(Service::VolunteerApprovalReminder).to receive(:record_outcome!).and_raise('Later outcome write unavailable')
      allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('production')
      allow(Service::SlackConnector).to receive(:update_slack_message).and_return('ok' => true)

      expect { event.close!(organizer) }.to raise_error('Later outcome write unavailable')

      expect(event.reload.status).to eq('closed')
      expect(event.approval_notification).to include(
        'ts' => '123.456', 'channel' => 'CREVIEW', 'closed_at' => event.closed_at, 'finalized' => true
      )
      expect(event.approval_notification['outcome']).to start_with('Credit award not confirmed')
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        'CREVIEW', '123.456', a_string_including('⚠️', 'Credit award not confirmed'), resolved_channel: true
      ).once
      expect(VolunteerCredit.where(member_id: attendee.id, issued_by_id: organizer.id, status: 'approved').count).to eq(1)
    end
  end
end
