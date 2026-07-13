# In config/initializers/devise.rb, find the line:
#   config.mailer_sender = ENV.fetch('SMTP_FROM', 'contact@manchestermakerspace.org')
#
# Add this line directly below it:
#   config.mailer = 'DeviseMailer'
#
# So it reads:
#   config.mailer_sender = ENV.fetch('SMTP_FROM', 'contact@manchestermakerspace.org')
#   config.mailer = 'DeviseMailer'
#
# That's the only change needed in devise.rb.
# DeviseMailer inherits Devise::Mailer and adds the after_action callback.
# All existing Devise email behaviour (password reset, confirmation, etc.) is preserved.
