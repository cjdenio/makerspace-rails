class MemberSummarySerializer < ActiveModel::Serializer
  attributes :id,
             :firstname,
             :lastname,
             :expirationTime,
             :email,
             :status,
             :role,
             :member_contract_signed_date,
             :member_contract_on_file,
             :totp_enabled,
             :notes,
             :household,
             :mailtrap,
             :slack,
             :checkout_approver_shop_ids,
             :firebase_uid

  attribute :is_checkout_approver do
    CheckoutApprover.exists?(member_id: object.id)
  end

  attribute :checkout_approver_shop_ids do
    CheckoutApprover.find_by(member_id: object.id)&.shop_ids || []
  end

  def member_contract_on_file
    !object.member_contract_signed_date.nil?
  end

  def totp_enabled
    object.otp_required_for_login? && object.otp_secret_encrypted.present?
  end

  def household
    group = object.group
    return nil unless group

    {
      group_name: group.groupName,
      display_name: group.group_display_name,
      role: object.household_role,
      primary_member_name: group.groupRep,
      member_count: group.active_members.count
    }
  end

  def mailtrap
    event = current_email_mailtrap_event
    return unknown_mailtrap_status unless event

    {
      id: event.id,
      timestamp: event.occurred_at&.in_time_zone("Eastern Time (US & Canada)")&.iso8601,
      email: event.email,
      status: event.status,
      value: event.status
    }
  end

  def current_email_mailtrap_event
    current_email = object.email.to_s.downcase
    linked_event = object.mailtrap_event
    return linked_event if linked_event&.email.to_s.downcase == current_email

    if instance_options.key?(:mailtrap_events_by_member_id_email)
      return preloaded_mailtrap_event(current_email)
    end

    MailtrapEvent.where(member_id: object.id, email: current_email).desc(:occurred_at).first
  end

  def preloaded_mailtrap_event(current_email)
    instance_options[:mailtrap_events_by_member_id_email][[object.id.to_s, current_email]]
  end

  def unknown_mailtrap_status
    {
      id: nil,
      timestamp: nil,
      email: object.email,
      status: "unknown",
      value: "No attempts made"
    }
  end

  def slack
    slack_user = object.slack_user
    return nil unless slack_user

    {
      slack_id: slack_user.slack_id,
      name: slack_user.real_name.presence || slack_user.name,
      url: ::Service::SlackConnector.slack_user_url(slack_user.slack_id)
    }
  end
end
