class RegistrationsController < ApplicationController
  include BraintreeGateway
  include ApplicationHelper
  respond_to :json

  # GET /api/signup_status
  # Public, unauthenticated check so the signup UI can redirect to a
  # maintenance page without needing admin credentials to read SystemConfig.
  def status
    render json: { locked: SystemConfig.enabled?(SystemConfig::SIGNUP_LOCKOUT_ENABLED) }, status: :ok
  end

  def new
    if signup_locked?
      render_signup_locked and return
    end

    email = new_member_params[:email].to_s.strip.downcase
    member = Member.find_by(email: email)
    if member
      error = "Cannot send registration to #{email}. Account already exists"
      enque_message(error)
      raise ::Error::AccountExists
    end
    MemberMailer.welcome_email(email).deliver_later
    render json: {}, status: 204 and return
  end

  def create
    if signup_locked?
      render_signup_locked and return
    end

    unless turnstile_valid?
      render json: Error::Helpers::Render.json(
        :forbidden,
        403,
        "Turnstile verification failed"
      ), status: :forbidden
      return
    end

    @member = Member.new(member_params)
    @member.status = 'pending'
    @member.save!
    @member.reload
    sign_in(@member)
    MemberMailer.member_registered(@member.id.to_s).deliver_later

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'member_registered',
      resource_type:  'Member',
      resource_id:    @member.id,
      actor:          @member,
      subject:        @member,
      after_snapshot: { email: @member.email, firstname: @member.firstname,
                        lastname: @member.lastname }
    )

    render json: @member, adapter: :attributes and return
  end

  private

  def signup_locked?
    SystemConfig.enabled?(SystemConfig::SIGNUP_LOCKOUT_ENABLED)
  end

  def render_signup_locked
    render json: Error::Helpers::Render.json(
      :forbidden,
      403,
      "Signups are currently disabled for maintenance."
    ), status: :forbidden
  end

  def turnstile_valid?
    ::Service::TurnstileVerifier.new(
      token: params['cf-turnstile-response'],
      remote_ip: Current.ip_address.presence || request.remote_ip
    ).valid?
  end

  def new_member_params
    params.require(:email)
    params.permit(:email)
  end 

  def member_params
    params.require([:firstname, :lastname, :email, :password])
    params.permit(:firstname, :lastname, :email, :password,
      :phone, address: [:street, :unit, :city, :state, :postal_code])
  end
end
