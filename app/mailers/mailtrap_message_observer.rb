# Registered via ActionMailer::Base.register_observer in config/initializers/mailtrap_observer.rb
# Fires after every outbound email is fully built, before delivery.
# At this point message.message_id is populated and we can store subject context
# so Mailtrap webhook events can be joined back to the original email.
class MailtrapMessageObserver
  def self.delivered_email(message)
    msg_id = message.message_id.to_s.gsub(/\A<|>\z/, '')
    return if msg_id.blank?

    recipient = Array(message.to).first
    return if recipient.blank?

    member = Member.where(email: recipient).first

    MailtrapMessage.create(
      message_id:   msg_id,
      subject:      message.subject.to_s,
      email:        recipient,
      mailer_class: message[:mailer_class]&.value.to_s,
      action:       message[:action_name]&.value.to_s,
      member_id:    member&.id
    )

    audit_email_sent(message, member) if member
  rescue => e
    Rails.logger.error("[MailtrapMessageObserver] Failed to record message #{msg_id}: #{e.class} #{e.message}")
    Honeybadger.notify(e) if defined?(Honeybadger)
  end

  # No slack_channel is passed -- every outgoing email would otherwise flood
  # whichever channel got picked, and this is meant as a quiet member-history
  # trail alongside the Mailtrap tab, not a notification.
  def self.audit_email_sent(message, member)
    mailer_class = message[:mailer_class]&.value
    action_name  = message[:action_name]&.value

    ::Service::AuditLogger.log(
      log_type:        'member',
      event_type:      'system_email_sent',
      resource_type:   'Member',
      resource_id:     member.id,
      subject:         member,
      message_details: "Sent \"#{message.subject}\"#{" via #{mailer_class}##{action_name}" if mailer_class}"
    )
  end
end
