class ToolCheckoutRequestSerializer < ActiveModel::Serializer
  attribute(:out_of_service) { !!object.tool&.out_of_service }
  attribute :requestor_annotation do
    object.target&.effective_requestor_annotation
  end
  attributes :id, :member_id, :member_name, :member_email, :member_status, :tool_id, :tool_name,
             :shop_id, :shop_name, :note, :request_date, :status, :message_id,
             :checked_out_id, :member_slack_url
  attributes :decided_at, :decision_reason
  attribute(:decided_by_name) { object.decided_by&.fullname }
  attribute(:tool_group_id) { object.tool_group_id }
  attribute(:target_type) { object.tool_group_id ? 'group' : 'tool' }
  attribute(:target_name) { object.target&.name }
  attribute(:group_revision) { object.tool_group&.revision }
  attribute(:included_tool_ids) { object.tool_group&.included_tool_ids || [] }

  def member_name
    object.member.try(:fullname)
  end

  def member_email
    object.member.try(:email)
  end

  def member_status
    object.member.try(:status)
  end

  def member_slack_url
    slack_user = object.member.try(:slack_user)
    return nil unless slack_user
    ::Service::SlackConnector.slack_user_url(slack_user.slack_id)
  end

  def tool_name
    object.target.try(:name)
  end

  def shop_id
    object.target.try(:shop_id)
  end

  def shop_name
    object.target.try(:shop).try(:name)
  end
end
