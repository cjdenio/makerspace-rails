class MarketingMailer < ApplicationMailer
  after_action :prevent_unwanted_send

  def prevent_unwanted_send
    mail.perform_deliveries = false if delivery_recipient_member&.silence_emails
  end

  # Ask users that aren't members to sign up
  def request_signup(member_id)
    @member = Member.find(member_id)
    mail to: @member.email, subject: "Manchester Makerspace Membership"
  end
end