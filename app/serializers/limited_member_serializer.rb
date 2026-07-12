class LimitedMemberSerializer < ActiveModel::Serializer
  attributes :id, :firstname, :lastname, :expirationTime, :email, :status,
             :member_contract_on_file, :slack

  def member_contract_on_file
    object.member_contract_signed_date.present?
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
