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

  after_create :close_open_request, :invite_member_to_users_channel

  def active?
    revoked_at.nil?
  end

  # Notify member via Slack DM when checked out
  def send_checkout_slack_notification
    slack_user = SlackUser.find_by(member_id: self.member_id)
    return if slack_user.nil? || member.direct_notifications_suppressed?

    shop_name = self.tool.shop.try(:name) || "the shop"
    tool_name = self.tool.name
    approver_name = self.approved_by.try(:fullname) || "an admin"
    message = "You have been checked out on *#{tool_name}* in *#{shop_name}* by #{approver_name}. You are now approved to use this tool."
    ::Service::SlackConnector.send_slack_message(message, slack_user.slack_id)
  end

  # Notify member via Slack DM when revoked
  def send_revocation_slack_notification
    slack_user = SlackUser.find_by(member_id: self.member_id)
    return if slack_user.nil? || member.direct_notifications_suppressed?

    shop_name = self.tool.shop.try(:name) || "the shop"
    tool_name = self.tool.name
    message = "Your checkout for *#{tool_name}* in *#{shop_name}* has been revoked. Please contact an admin if you have questions."
    ::Service::SlackConnector.send_slack_message(message, slack_user.slack_id)
  end

  def announce_checkout_success
    return unless tool.announce?

    request = ToolCheckoutRequest.where(
      member_id: member_id,
      tool_id: tool_id,
      status: "closed",
      checked_out_id: id
    ).first
    channel = tool.announce_channel.presence || tool.shop.try(:slack_channel)
    return if channel.blank?

    message = "*#{member.fullname}* has been checked out on *#{tool.name}* in *#{tool.shop.try(:name)}*."
    if request&.message_id.present?
      ::Service::SlackConnector.update_slack_message(channel, request.message_id, message)
    else
      response = ::Service::SlackConnector.send_slack_message(message, channel)
      request.update_attributes!(message_id: response.ts) if request && response.respond_to?(:ts)
    end
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end

  def remove_member_from_users_channel
    return if tool.users_channel.blank?

    slack_user = SlackUser.find_by(member_id: member_id)
    return if slack_user.nil?

    ::Service::SlackConnector.kick_from_channel(tool.users_channel, slack_user.slack_id)
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end

  private

  def close_open_request
    request = ToolCheckoutRequest.where(member_id: member_id, tool_id: tool_id, status: "open").first
    request.update_attributes!(status: "closed", checked_out_id: id) if request
  end

  def invite_member_to_users_channel
    return if tool.users_channel.blank?

    slack_user = SlackUser.find_by(member_id: member_id)
    return if slack_user.nil?

    ::Service::SlackConnector.invite_to_channel(tool.users_channel, slack_user.slack_id)
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end
end
