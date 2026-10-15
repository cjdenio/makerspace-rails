# Registered via ActionMailer::Base.register_interceptor in
# config/initializers/mailtrap_observer.rb. Runs before delivery -- unlike
# MailtrapMessageObserver, which runs after the message is already sent --
# so this is the one point where a header can still be attached for Mailtrap
# to echo back in its webhook events later.
#
# Mailtrap's own webhook "message_id" is its internal tracking id, generated
# independently of the SMTP Message-ID header we set, so the two never match.
# Setting our own id as a custom variable gives the webhook handler a value
# it actually generated and can look back up.
class MailtrapCustomVariableInterceptor
  def self.delivering_email(message)
    msg_id = message.message_id.to_s.gsub(/\A<|>\z/, '')
    return if msg_id.blank?

    message['X-MT-Custom-Variables'] = { app_message_id: msg_id }.to_json
  rescue => e
    Rails.logger.error("[MailtrapCustomVariableInterceptor] Failed to tag message #{msg_id}: #{e.class} #{e.message}")
    Honeybadger.notify(e) if defined?(Honeybadger)
  end
end
