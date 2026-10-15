require 'rails_helper'

RSpec.describe MailtrapMessageObserver do
  let(:member) { create(:member, email: 'observer-member@example.com') }

  def build_message(to:, subject:, message_id:, mailer_class: 'MemberMailer', action_name: 'password_changed')
    message = Mail::Message.new
    message.to = to
    message.subject = subject
    message.message_id = message_id
    message['mailer_class'] = mailer_class
    message['action_name'] = action_name
    message
  end

  before do
    allow(Service::AuditLogger).to receive(:log)
  end

  it 'records the message and logs a system_email_sent audit entry when the recipient is a known member' do
    message = build_message(to: member.email, subject: 'Your password was changed', message_id: 'abc123@example.com')

    described_class.delivered_email(message)

    stored = MailtrapMessage.find_by(message_id: 'abc123@example.com')
    expect(stored.subject).to eq('Your password was changed')
    expect(stored.member_id).to eq(member.id)

    expect(Service::AuditLogger).to have_received(:log).with(
      hash_including(
        log_type:      'member',
        event_type:    'system_email_sent',
        resource_type: 'Member',
        resource_id:   member.id,
        subject:       member,
        message_details: a_string_matching(/Your password was changed.*MemberMailer#password_changed/)
      )
    )
  end

  it 'does not log an audit entry when the recipient is not a known member' do
    message = build_message(to: 'someone-else@example.com', subject: 'Unrelated', message_id: 'def456@example.com')

    described_class.delivered_email(message)

    expect(Service::AuditLogger).not_to have_received(:log)
  end

  it 'still records the Mailtrap message even if audit logging raises' do
    message = build_message(to: member.email, subject: 'Receipt', message_id: 'ghi789@example.com')
    allow(Service::AuditLogger).to receive(:log).and_raise(StandardError.new('boom'))
    allow(Honeybadger).to receive(:notify)

    expect { described_class.delivered_email(message) }.not_to raise_error
    expect(MailtrapMessage.find_by(message_id: 'ghi789@example.com')).to be_present
  end
end
