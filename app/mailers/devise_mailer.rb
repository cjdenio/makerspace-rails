class DeviseMailer < Devise::Mailer
  # Intentionally empty — no after_action needed.
  # MailtrapMessageObserver handles message capture for all mailers globally
  # via ActionMailer::Base.register_observer in config/initializers/mailtrap_observer.rb
end
