module MobileSessionPersistence
  extend ActiveSupport::Concern
  include Devise::Controllers::Rememberable

  # Run before authentication: Devise otherwise writes a remember cookie as
  # soon as the password strategy succeeds, before our TOTP challenge.
  def prepare_mobile_session_persistence
    credentials = controller_name == 'sessions' ? params[:member] : params
    return if controller_name == 'sessions' && credentials.blank?

    @mobile_login_attempt = true
    @mobile_remember_requested = MobileSessionClient.phone?(request.user_agent) &&
      Devise::TRUE_VALUES.include?(credentials[:remember_me])
    credentials[:remember_me] = false
  end

  def stage_mobile_session_persistence(member)
    return unless @mobile_login_attempt

    # Both callers have now passed CSRF and authenticated an eligible member.
    # Failed retries must preserve the original pending choice and credential.
    # A successful replacement clears the old choice even when opting out.
    session.delete(:mobile_remember_pending)
    cookies.delete('remember_member_token', forget_cookie_values(member))
    return unless @mobile_remember_requested

    session[:mobile_remember_pending] = {
      'member_id' => member.id.to_s,
      'salt' => member.authenticatable_salt,
      'expires_at' => 10.minutes.from_now.to_i
    }
  end

  def complete_mobile_session_persistence(member)
    pending = session.delete(:mobile_remember_pending)
    return unless pending && pending['member_id'] == member.id.to_s &&
      pending['expires_at'].to_i > Time.current.to_i &&
      pending['salt'] == member.authenticatable_salt &&
      member.send(:active_for_authentication?)

    remember_me(member)
  end
end
