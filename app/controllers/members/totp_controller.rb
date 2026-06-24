class Members::TotpController < AuthenticationController
  before_action :set_member

  # POST /api/members/totp/setup
  # Generates a new secret and QR code but does NOT activate TOTP yet.
  # The member must verify a valid code before TOTP is activated.
  def setup
    # Generate a new pending secret — store in session until verified
    plain_secret = TotpService.generate_secret
    session[:totp_pending_secret] = plain_secret

    render json: {
      secret:  plain_secret,
      qr_code: TotpService.qr_svg(@member, plain_secret)
    }, status: :ok
  end

  # POST /api/members/totp/verify
  # Confirms enrollment by validating the first code against the pending secret.
  def verify
    plain_secret = session[:totp_pending_secret]
    code         = params[:code].to_s.strip

    if plain_secret.blank?
      render json: { error: 'Setup session expired. Please start over.' }, status: :unprocessable_entity and return
    end

    unless TotpService.valid?(code, TotpService.encrypt(plain_secret))
      render json: { error: 'Invalid code. Please try again.' }, status: :unprocessable_entity and return
    end

    # Activate TOTP
    @member.update!(
      otp_secret_encrypted:   TotpService.encrypt(plain_secret),
      otp_required_for_login: true,
      otp_enabled_at:         Time.now
    )
    session.delete(:totp_pending_secret)

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'totp_enabled',
      resource_type:  'Member',
      resource_id:    @member.id,
      actor:          current_member,
      subject:        @member,
      slack_channel:  ::Service::SlackConnector.logs_channel
    )

    render json: { message: 'Two-factor authentication enabled.' }, status: :ok
  end

  # DELETE /api/members/totp
  # Member disables their own TOTP.
  def destroy
    @member.update!(
      otp_secret_encrypted:   nil,
      otp_required_for_login: false,
      otp_enabled_at:         nil
    )

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'totp_disabled',
      resource_type:  'Member',
      resource_id:    @member.id,
      actor:          current_member,
      subject:        @member,
      slack_channel:  ::Service::SlackConnector.logs_channel
    )

    render json: { message: 'Two-factor authentication disabled.' }, status: :ok
  end

  private

  def set_member
    @member = current_member
  end
end
