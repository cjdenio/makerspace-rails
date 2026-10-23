class CheckoutMailer < ApplicationMailer
  def expiration_notice(member_id, rows, kind)
    @member = Member.find(member_id)
    @rows = rows.map(&:symbolize_keys)
    @heading = kind == 'expired' ? 'Your tool checkouts have expired' : 'Your tool checkouts expire soon'
    @portal_url = CheckoutExpirationNotice.portal_url
    mail to: @member.email, subject: "Manchester Makerspace — #{@heading}"
  end
end
