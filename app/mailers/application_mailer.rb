class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('SMTP_FROM', 'contact@manchestermakerspace.org')
  layout 'mailer'
end
