class Members::PasswordsController < AuthenticationController
  # PUT /api/members/password
  # Authenticated member changes their own password directly (no reset token required).
  def update
    password = password_params[:password]
    raise ::Error::UnprocessableEntity.new("Password cannot be blank") if password.blank?
    raise ::Error::UnprocessableEntity.new("Password is too short (minimum 8 characters)") if password.length < 8

    current_member.password = password
    current_member.save!

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'password_changed',
      resource_type:  'Member',
      resource_id:    current_member.id,
      actor:          current_member,
      subject:        current_member
    )

    render json: {}, status: 204 and return
  end

  private
  def password_params
    params.require(:password)
    params.permit(:password)
  end
end
