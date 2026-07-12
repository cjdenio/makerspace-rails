class Members::TotpSessionsController < ApplicationController
  # POST /api/members/totp_sessions
  # Validates the TOTP code during the login flow and issues a full session.
  def create
    pending_id  = session[:totp_pending_member_id]
    expires_at  = session[:totp_pending_expires_at].to_i
    code        = params[:code].to_s.strip

    # Validate pending state
    if pending_id.blank?
      render json: { error: 'Session expired. Please sign in again.' }, status: :unauthorized and return
    end

    if Time.now.to_i > expires_at
      session.delete(:totp_pending_member_id)
      session.delete(:totp_pending_expires_at)
      render json: { error: 'Session expired. Please sign in again.' }, status: :unauthorized and return
    end

    member = Member.find(pending_id)
    if member.nil? || !member.otp_required_for_login?
      render json: { error: 'Invalid session.' }, status: :unauthorized and return
    end

    unless TotpService.valid?(code, member.otp_secret_encrypted)
      render json: { error: 'Invalid code. Please try again.' }, status: :unprocessable_content and return
    end

    # Code valid — clean up pending state and issue full session
    session.delete(:totp_pending_member_id)
    session.delete(:totp_pending_expires_at)

    sign_in(:member, member)
    render json: member, adapter: :attributes and return
  end
end
