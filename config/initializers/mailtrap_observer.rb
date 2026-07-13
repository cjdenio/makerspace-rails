# Register the observer that captures email subject/context for the Mailtrap
# email log feature. Fires after every outbound email is fully built.
Rails.application.config.after_initialize do
  ActionMailer::Base.register_observer(MailtrapMessageObserver)
end
