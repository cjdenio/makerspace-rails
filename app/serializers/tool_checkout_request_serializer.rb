class ToolCheckoutRequestSerializer < ActiveModel::Serializer
  attributes :id, :member_id, :member_name, :member_email, :tool_id, :tool_name,
             :shop_id, :shop_name, :note, :request_date, :status, :message_id,
             :checked_out_id, :member_slack_url

  def member_name
    object.member.try(:fullname)
  end

  def member_email
    object.member.try(:email)
  end

  def member_slack_url
    slack_user = object.member.try(:slack_user)
    return nil unless slack_user
    ::Service::SlackConnector.slack_user_url(slack_user.slack_id)
  end

  def tool_name
    object.tool.try(:name)
  end

  def shop_id
    object.tool.try(:shop_id)
  end

  def shop_name
    object.tool.try(:shop).try(:name)
  end
end
