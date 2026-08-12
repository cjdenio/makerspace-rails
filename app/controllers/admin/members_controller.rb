class Admin::MembersController < AdminController
  include Service::GoogleDrive
  before_action :set_member, only: [:update, :update_password, :send_password_reset, :invite_google_drive, :invite_slack]

  def create
    permitted_params = get_camel_case_params(create_member_params())
    normalize_and_validate_rm_assignments!(permitted_params)
    authorize_silence_emails_change!(permitted_params, Member.new(status: permitted_params[:status]))

    @member = Member.new(permitted_params)
    @member.save!
    @member.reload
    send_welcome_email
    enqueue_rm_canvas_access_sync([], rm_shop_ids_for(@member))
    render json: @member, serializer: MemberSerializer, adapter: :attributes,
      include_provisioning: true and return
  end

  def update
    before = @member.attributes.dup
    previous_rm_shop_ids = rm_shop_ids_for(@member)
    date = @member.expirationTime
    becoming_revoked   = params[:status] == 'revoked'   && @member.status != 'revoked'
    becoming_suspended = params[:status] == 'suspended' && @member.status != 'suspended'

    @member.skip_email_deliverability_validation = true if becoming_revoked

    permitted_params = get_camel_case_params(update_member_params())
    normalize_and_validate_rm_assignments!(permitted_params, @member)
    authorize_silence_emails_change!(permitted_params, @member)

    @member.update!(permitted_params)

    # Capture field changes from THIS save immediately — handle_revocation
    # and invalidate_member_sessions below perform their own saves (e.g.
    # session_token rotation), which would otherwise overwrite
    # previous_changes by the time the audit log reads it below, causing
    # the status change to be lost and the rotated session_token to leak
    # into field_changes (which AuditLogger does not scrub, unlike
    # before/after snapshots).
    member_field_changes = @member.previous_changes

    if becoming_revoked
      handle_revocation
    elsif becoming_suspended
      invalidate_member_sessions
    end

    notify_renewal(date)

    @member.reload

    # Log membership revocation as its own dedicated event
    if becoming_revoked
      Service::AuditLogger.log(
        log_type:        'member',
        event_type:      'membership_revoked',
        resource_type:   'Member',
        resource_id:     @member.id,
        actor:           current_member,
        subject:         @member,
        field_changes:   member_field_changes,
        before_snapshot: before,
        after_snapshot:  @member.attributes,
        slack_channel:   ::Service::SlackConnector.logs_channel
      )
    else
      Service::AuditLogger.log(
        log_type:        'member',
        event_type:      'member_updated',
        resource_type:   'Member',
        resource_id:     @member.id,
        actor:           current_member,
        subject:         @member,
        field_changes:   member_field_changes,
        before_snapshot: before,
        after_snapshot:  @member.attributes,
        slack_channel:   ::Service::SlackConnector.logs_channel
      )
    end

    enqueue_rm_canvas_access_sync(
      previous_rm_shop_ids,
      rm_shop_ids_for(@member)
    )

    render json: @member, serializer: MemberSerializer, adapter: :attributes,
      include_provisioning: true and return
  end

  # POST /api/admin/members/:id/update_password
  # Admin directly sets a new password for any member, then emails a notification.
  def update_password
    password = password_params[:password]
    raise ::Error::UnprocessableEntity.new("Password cannot be blank") if password.blank?
    raise ::Error::UnprocessableEntity.new("Password is too short (minimum 8 characters)") if password.length < 8

    @member.password = password
    @member.save!
    MemberMailer.password_changed(@member.id.to_s).deliver_later

    Service::AuditLogger.log(
      log_type:      'member',
      event_type:    'password_changed',
      resource_type: 'Member',
      resource_id:   @member.id,
      actor:         current_member,
      subject:       @member,
      slack_channel: ::Service::SlackConnector.logs_channel
    )

    render json: {}, status: 204 and return
  end

  # POST /api/admin/members/:id/send_password_reset
  # Admin triggers a Devise reset-link email (member sets their own password via link).
  def send_password_reset
    send_set_password_email
    render json: {}, status: 204 and return
  end

  # POST /api/admin/members/:id/invite_google_drive
  # Re-sends a Google Drive folder invite to the member.
  def invite_google_drive
    ::Service::MemberProvisioning.provision_google(@member, raise_errors: true)
    render json: {}, status: 204 and return
  rescue Error::NotAllowed => e
    render json: { message: e.message }, status: :unprocessable_content and return
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
    render json: { message: e.message }, status: :unprocessable_content and return
  end

  # POST /api/admin/members/:id/invite_slack
  # Re-sends a Slack workspace invite to the member's email.
  # Safe to call even if the member is already in the workspace — Slack
  # will return an error which is surfaced to the admin.
  def invite_slack
    ::Service::MemberProvisioning.invite_slack(@member, raise_errors: true)
    render json: {}, status: 204 and return
  rescue Error::NotAllowed => e
    render json: { message: e.message }, status: :unprocessable_content and return
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
    render json: { message: e.message }, status: :unprocessable_content and return
  end

  private

  # Cancel subscription, revoke Drive/Slack access, and invalidate all sessions
  # when a member's status is set to revoked.
  def handle_revocation
    # Cancel Braintree subscription if present
    if @member.subscription_id
      begin
        ::BraintreeService::Subscription.cancel(connect_gateway, @member.subscription_id)
      rescue => e
        ::Service::SlackConnector.send_slack_message(
          "⚠️ Error cancelling subscription for revoked member #{@member.fullname}: #{e.message}",
          ::Service::SlackConnector.logs_channel
        )
      end
    end

    # Revoke Google Drive and Slack access
    begin
      Service::MemberAccess.revoke(@member)
    rescue => e
      ::Service::SlackConnector.send_slack_message(
        "⚠️ Error revoking Drive/Slack access for #{@member.fullname}: #{e.message}",
        ::Service::SlackConnector.logs_channel
      )
    end

    # Keep marketing mail silenced; revoked status suppresses direct member email/Slack notifications.
    @member.update_attribute(:silence_emails, true)

    # Rotate session token to invalidate any active portal sessions
    invalidate_member_sessions
  end

  # Rotate session token to invalidate any active portal sessions
  # when a member is blocked from authentication.
  def invalidate_member_sessions
    @member.update_attribute(:session_token, SecureRandom.hex)
  end

  def authorize_silence_emails_change!(permitted_params, member)
    return unless permitted_params.key?(:silence_emails)

    boolean_type = ActiveModel::Type::Boolean.new
    requested_value = boolean_type.cast(permitted_params[:silence_emails]) || false
    current_value = boolean_type.cast(member.silence_emails) || false
    return if requested_value == current_value

    return if member.id == current_member.id && (is_admin? || is_board_member?)

    if is_admin?
      raise Error::Forbidden.new if member.status == 'revoked'
      return
    end

    raise Error::Forbidden.new unless is_board_member? && requested_value == true
  end

  def create_member_params
    params.require([:firstname, :lastname, :email])
    params.permit(:firstname, :lastname, :role, :email, :status,
      :silence_emails, :member_contract_on_file, :phone, :notes,
      resource_manager_shop_ids: [], resourceManagerShopIds: [],
      address: [:street, :city, :state, :postal_code])
  end

  def update_member_params
    params.permit(:firstname, :lastname, :role, :status, :expiration_time, :renew, :member_contract_on_file, :notes,
      :silence_emails, :phone, :subscription, :email,
      resource_manager_shop_ids: [], resourceManagerShopIds: [],
      address: [:street, :unit, :city, :state, :postal_code])
  end

  def password_params
    params.require(:password)
    params.permit(:password)
  end

  def get_camel_case_params(member_params)
    camel_case_props = {
      expiration_time: :expirationTime,
      member_contract_on_file: :memberContractOnFile,
    }
    params = member_params
    if params[:resourceManagerShopIds].present? || params.key?(:resourceManagerShopIds)
      params[:resource_manager_shop_ids] = params.delete(:resourceManagerShopIds)
    end
    camel_case_props.each do | key, value|
      params[value] = params.delete(key) unless params[key].nil?
    end
    params
  end

  def normalize_and_validate_rm_assignments!(permitted_params, member = nil)
    role = permitted_params[:role].presence || member&.role
    if role != "resource_manager"
      permitted_params[:resource_manager_shop_ids] = [] if permitted_params.key?(:role) || permitted_params.key?(:resource_manager_shop_ids)
      return
    end

    ids = if permitted_params.key?(:resource_manager_shop_ids)
      Array(permitted_params[:resource_manager_shop_ids]).map(&:to_s).uniq
    else
      Array(member&.resource_manager_shop_ids).map(&:to_s)
    end
    raise ::Error::UnprocessableEntity.new("Select at least one shop for a Resource Manager") if ids.empty?

    valid_ids = Shop.where(:id.in => ids).pluck(:id).map(&:to_s)
    raise ::Error::UnprocessableEntity.new("One or more Resource Manager shops are invalid") unless (ids - valid_ids).empty?
    permitted_params[:resource_manager_shop_ids] = ids
  end

  def rm_shop_ids_for(member)
    return [] unless member.role == "resource_manager"

    Array(member.resource_manager_shop_ids).map(&:to_s).uniq
  end

  def enqueue_rm_canvas_access_sync(previous_shop_ids, current_shop_ids)
    previous_shop_ids = Array(previous_shop_ids).map(&:to_s).uniq
    current_shop_ids = Array(current_shop_ids).map(&:to_s).uniq
    return if previous_shop_ids.sort == current_shop_ids.sort

    affected_shop_ids = previous_shop_ids | current_shop_ids
    return if affected_shop_ids.empty?

    ReservationSlackCanvasMemberAccessJob.perform_later(
      @member.id.to_s,
      affected_shop_ids
    )
  end

  def set_member
    @member = Member.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: params[:id] }) if @member.nil?
  end

  def notify_renewal(init)
    final = @member.expirationTime
    # Check if adding expiration too
    if final &&
        (init.nil? ||
        (Time.at(final / 1000) - Time.at((init || 0) / 1000) > 1.day))
      @member.send_renewal_slack_message(current_member)
    end
  end

  def send_welcome_email
    raw_token, hashed_token = ::Devise.token_generator.generate(Member, :reset_password_token)
    @member.reset_password_token = hashed_token
    @member.reset_password_sent_at = Time.now.utc
    @member.save!
    MemberMailer.welcome_email_manual_register(@member.email, raw_token).deliver_now
  end

  def send_set_password_email
    @member.send_reset_password_instructions
  end
end
