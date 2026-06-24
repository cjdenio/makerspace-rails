class RentalMailer < ApplicationMailer
  ADMIN_EMAIL = "contact@manchestermakerspace.org".freeze

  def rental_request_pending(member_id, rental_id, spot_id)
    @member = Member.find(member_id)
    @rental = Rental.find(rental_id)
    @spot   = RentalSpot.find(spot_id)
    mail(to: ADMIN_EMAIL, subject: "Rental Request Pending Approval — #{@member.fullname} / #{@spot.number}")
  end

  def rental_request_approved(member_id, rental_id)
    @member      = Member.find(member_id)
    @rental      = Rental.find(rental_id)
    @profile_url = "#{Rails.configuration.action_mailer.default_url_options[:host]}/members/#{@member.id}/invoices"
    mail(to: @member.email, subject: "Your Rental Request Has Been Approved — Manchester Makerspace")
  end

  def rental_claimed(member_id, rental_id)
    @member      = Member.find(member_id)
    @rental      = Rental.find(rental_id)
    @profile_url = "#{Rails.configuration.action_mailer.default_url_options[:host]}/members/#{@member.id}/invoices"
    mail(to: @member.email, subject: "Rental Claimed — Payment Required — Manchester Makerspace")
  end

  def rental_request_denied(member_id, rental_id, reason)
    @member = Member.find(member_id)
    @rental = Rental.find(rental_id)
    @reason = reason
    mail(to: @member.email, subject: "Update on Your Rental Request — Manchester Makerspace")
  end

  def rental_ended(member_id, rental_id)
    @member = Member.find(member_id)
    @rental = Rental.find(rental_id)
    mail(to: @member.email, subject: "Your Rental Has Ended — Manchester Makerspace")
  end

  def rental_vacating(member_id, rental_id, expiry)
    @member = Member.find(member_id)
    @rental = Rental.find(rental_id)
    @expiry = expiry
    mail(to: @member.email, subject: "Rental Cancellation Confirmation — Manchester Makerspace")
  end
end
