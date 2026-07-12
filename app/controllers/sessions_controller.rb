class SessionsController < Devise::SessionsController
  # POST /api/members/sign_in
  def create
    resource = warden.authenticate!(:scope => resource_name, :recall => "#{controller_path}#new")

    # Explicitly check active_for_authentication? — warden.authenticate! with :recall
    # does not raise on inactive members, it just calls the recall action and continues.
    # Without this check, revoked/suspended members can still complete sign-in.
    # active_for_authentication? is protected in Devise so we use send.
    unless resource&.send(:active_for_authentication?)
      if resource
        message = I18n.t("devise.failure.#{resource.send(:inactive_message)}")
        # Security audit — log and notify on blocked login attempts
        Rails.logger.warn("[Security] Blocked login attempt for #{resource.status} member: #{resource.email}")
        AuditLog.create!(
          event_type:  'blocked_login_attempt',
          actor_id:    resource.id,
          actor_name:  resource.fullname,
          description: "Login blocked — member status: #{resource.status}"
        ) rescue nil
        ::Service::SlackConnector.send_slack_message(
          "🚫 #{resource.status.capitalize} member #{resource.fullname} (#{resource.email}) attempted portal login",
          ::Service::SlackConnector.logs_channel
        ) rescue nil
      else
        message = I18n.t('devise.failure.invalid', authentication_keys: 'email')
      end
      render json: { message: message }, status: :unauthorized and return
    end

    # Check if TOTP is enrolled — require code entry before issuing full session
    if resource.otp_required_for_login? && resource.otp_secret_encrypted.present?
      session[:totp_pending_member_id]      = resource.id.to_s
      session[:totp_pending_expires_at]     = 10.minutes.from_now.to_i
      render json: { totp_required: true }, status: :accepted and return
    end

    # Check if TOTP enrollment is required for this member's role but not yet set up
    if totp_enrollment_required?(resource) && !resource.otp_required_for_login?
      sign_in(resource_name, resource)
      member_json = ActiveModelSerializers::SerializableResource.new(
        resource,
        serializer: MemberSerializer,
        adapter: :attributes
      ).as_json
      render json: member_json.merge(totp_enrollment_required: true) and return
    end

    sign_in(resource_name, resource)
    render json: resource, adapter: :attributes and return
  end

  private

  def totp_enrollment_required?(member)
    case member.role
    when 'admin'            then SystemConfig.enabled?('require_totp_admin')
    when 'board_member'     then SystemConfig.enabled?('require_totp_board')
    when 'resource_manager' then SystemConfig.enabled?('require_totp_rm')
    else false
    end
  end
end