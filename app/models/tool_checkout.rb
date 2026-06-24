class ToolCheckout
  include Mongoid::Document
  include ActiveModel::Serializers::JSON
  include Service::SlackConnector

  field :checked_out_at, type: Time, default: -> { Time.now }
  field :revoked_at, type: Time
  field :revocation_reason, type: String  # internal only — not shown to member
  field :signed_off_via, type: String, default: "portal"  # "portal" or "slack"

  belongs_to :member
  belongs_to :tool
  belongs_to :approved_by, class_name: "Member", optional: true

  validates :member, presence: true
  validates :tool, presence: true

  def active?
    revoked_at.nil?
  end

  # Notify member via Slack DM when checked out
  def send_checkout_slack_notification
    slack_user = SlackUser.find_by(member_id: self.member_id)
    return if slack_user.nil? || self.member.silence_emails

    shop_name = self.tool.shop.try(:name) || "the shop"
    tool_name = self.tool.name
    approver_name = self.approved_by.try(:fullname) || "an admin"
    message = "You have been checked out on *#{tool_name}* in *#{shop_name}* by #{approver_name}. You are now approved to use this tool."
    ::Service::SlackConnector.send_slack_message(message, slack_user.slack_id)
  end

  # Notify member via Slack DM when revoked
  def send_revocation_slack_notification
    slack_user = SlackUser.find_by(member_id: self.member_id)
    return if slack_user.nil? || self.member.silence_emails

    shop_name = self.tool.shop.try(:name) || "the shop"
    tool_name = self.tool.name
    message = "Your checkout for *#{tool_name}* in *#{shop_name}* has been revoked. Please contact an admin if you have questions."
    ::Service::SlackConnector.send_slack_message(message, slack_user.slack_id)
  end
end
