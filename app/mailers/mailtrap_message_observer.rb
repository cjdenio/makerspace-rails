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
  rescue => e
    Rails.logger.error("[MailtrapMessageObserver] Failed to record message #{msg_id}: #{e.class} #{e.message}")
    Honeybadger.notify(e) if defined?(Honeybadger)
  end
end
