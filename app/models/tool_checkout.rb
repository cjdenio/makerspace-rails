class ToolCheckout
  include Mongoid::Document
  include ActiveModel::Serializers::JSON
  include Service::SlackConnector

  field :checked_out_at, type: Time, default: -> { Time.now }
  field :revoked_at, type: Time
  field :revocation_reason, type: String  # internal only — not shown to member
  field :signed_off_via, type: String, default: "portal"  # "portal", "slack" or "fob"
  field :volunteer_credit_id, type: BSON::ObjectId
  field :group_id, type: BSON::ObjectId
  field :group_revision, type: Integer
  field :group_name, type: String
  field :approval_batch_id, type: String
  attr_accessor :defer_group_callbacks
  attr_accessor :reconciled_requests
  index({ approval_batch_id: 1 })
  field :revocation_cleanup_pending, type: Boolean, default: false
  field :revoked_by_id, type: BSON::ObjectId
  field :revocation_cleanup_completed_steps, type: Array, default: []

  belongs_to :member
  belongs_to :tool
  belongs_to :approved_by, class_name: "Member", optional: true
  attr_accessor :checkout_request_id, :defer_users_channel_invitation, :approver_mutation_lock_held

  index({ member_id: 1, revoked_at: 1, tool_id: 1 })

  validates :member, presence: true
  validates :tool, presence: true

  after_create :close_open_request, unless: :defer_group_callbacks
  after_create :invite_member_to_users_channel, unless: :defer_users_channel_invitation
  after_create :enqueue_checkout_canvas_sync, unless: :defer_group_callbacks
  before_update :mark_revocation_cleanup_pending
  after_update :complete_revocation_cleanup, if: :revocation_cleanup_required?
  after_update :enqueue_checkout_canvas_sync_after_revocation

  def active?
    revoked_at.nil?
  end

  def newly_revoked?
    previous_changes.key?("revoked_at") && previous_changes["revoked_at"].first.nil? && revoked_at.present?
  end

  def revocation_cleanup_required?
    revoked_at.present? && (newly_revoked? || revocation_cleanup_pending?)
  end

  def mark_revocation_cleanup_pending
    revocation_change = changes["revoked_at"]
    return unless revocation_change && revocation_change.first.nil? && revocation_change.last.present?

    self.revocation_cleanup_pending = true
  end

  def complete_revocation_cleanup
    # The recovery marker was persisted in the same update as revoked_at.
    # Every step below is retry-safe, so a sweep can resume any partial failure.
    CheckoutApproverVolunteering.revoke_for!(member_id: member_id, tool_id: tool_id,
      approver_lock_held: approver_mutation_lock_held)
    CheckoutApproverCredit.reverse!(self)
    complete_revocation_side_effects if revoked_by_id.present?
    unset(:revocation_cleanup_pending)
    @completed_revocation_cleanup = true
  end

  def retry_revocation_cleanup!
    return unless revoked_at.present? && revocation_cleanup_pending?

    complete_revocation_cleanup
    enqueue_checkout_canvas_sync_after_revocation
  end

  def self.recover_pending_revocation_cleanups!
    where(revocation_cleanup_pending: true, :revoked_at.ne => nil).each do |checkout|
      checkout.retry_revocation_cleanup!
    rescue => error
      begin
        Service::ErrorReporter.notify(error, context: {
          phase: "recover checkout revocation cleanup",
          checkout_id: checkout.id.to_s
        })
      rescue => report_error
        Rails.logger.error("[CheckoutRevocationCleanup] reporting failed: #{report_error.class}")
      end
    end
  end

  def complete_revocation_side_effects
    complete_revocation_step("member_notified") { send_revocation_slack_notification }
    complete_revocation_step("approver_notified") do
      send_approver_revocation_slack_notification(Member.find_by(id: revoked_by_id))
    rescue => error
      Service::ErrorReporter.notify(error, context: {
        phase: "notify original approver of checkout revocation", checkout_id: id.to_s
      })
    end
    complete_revocation_step("users_channel_removed") { remove_member_from_users_channel }
    complete_revocation_step("audit_logged") { log_revocation_audit }
  end

  # Notify member via Slack DM when checked out
  def send_checkout_slack_notification
    slack_user = SlackUser.find_by(member_id: self.member_id)
    return if slack_user.nil? || member.direct_notifications_suppressed?

    shop_name = self.tool.shop.try(:name) || "the shop"
    tool_name = self.tool.name
    approver_name = self.approved_by.try(:fullname) || "an admin"
    message = "You have been checked out on *#{tool_name}* in *#{shop_name}* by #{approver_name}. You are now approved to use this tool."
    message += "\n\n*Notes:* #{self.tool.notes}" if self.tool.notes.present?
    ::Service::SlackConnector.send_slack_message(message, slack_user.slack_id)
  end

  # Re-send just the notes DM (e.g. /checkout request <tool> for a member
  # who already has an active checkout) -- a no-op if there's nothing to send.
  def send_notes_slack_notification
    return if tool.notes.blank?

    slack_user = SlackUser.find_by(member_id: self.member_id)
    return if slack_user.nil? || member.direct_notifications_suppressed?

    message = "*Notes for #{tool.name}:* #{tool.notes}"
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

  # Tell the original approver when another currently-authorized approver
  # revokes their approval. Ordinary recipients see only the revoker's role;
  # board/admin recipients may also see the revoker's name.
  def send_approver_revocation_slack_notification(revoked_by)
    original_approver = approved_by
    return if original_approver.nil? || revoked_by.nil? || original_approver.id == revoked_by.id
    return unless currently_approves_tool?(original_approver)

    slack_user = SlackUser.find_by(member_id: original_approver.id)
    return if slack_user.nil? || original_approver.direct_notifications_suppressed?

    checked_out_member_slack_id = SlackUser.find_by(member_id: member_id)&.slack_id
    checked_out_member = checked_out_member_slack_id.present? ? "<@#{checked_out_member_slack_id}>" : member.fullname
    revoker = revoker_description(revoked_by)
    if original_approver.role.in?(%w[admin board_member])
      revoker += " (#{revoked_by.fullname})"
    end
    date = checked_out_at&.to_date&.iso8601 || "an unknown date"
    message = "Your approval of checkout in *#{tool.shop&.name}* for *#{tool.name}* on #{date} " \
      "for member #{checked_out_member} has been revoked by #{revoker}."
    ::Service::SlackConnector.send_slack_message(message, slack_user.slack_id)
  end

  def announce_checkout_success
    request = ToolCheckoutRequest.where(
      member_id: member_id,
      tool_id: tool_id,
      status: "closed",
      checked_out_id: id
    ).first
    announce_channel = tool.announce? ? (tool.announce_channel.presence || tool.shop.try(:slack_channel)) : nil
    channels = [announce_channel, tool.users_channel.presence].compact.uniq
    return if channels.empty?
    target_channel = nil
    message = checkout_success_message
    sent_channels = []
    if announce_channel.present? && request&.message_id.present?
      target_channel = announce_channel
      Rails.logger.info("[announce_checkout_success] Updating '#{request.message_id}' in channel '#{announce_channel}'")
      ::Service::SlackConnector.update_slack_message(announce_channel, request.message_id, message)
      sent_channels << announce_channel
    end

    channels.each do |channel|
      next if sent_channels.include?(channel)
      target_channel = channel
      response = ::Service::SlackConnector.send_slack_message(message, channel)
      if channel == announce_channel && request && response.respond_to?(:ts)
        request.register_announcement(response.ts)
        if request.message_id != response.ts
          ::Service::SlackConnector.update_slack_message(channel, request.message_id, message)
          request.discard_duplicate_announcement(channel, response.ts)
        end
      end
    end
  rescue => e
    Service::ErrorReporter.notify(e, context: { channel: target_channel, member_id: member_id })
  end

  def remove_member_from_users_channel
    return if tool.users_channel.blank?

    slack_user = SlackUser.find_by(member_id: member_id)
    return if slack_user.nil?

    ::Service::SlackConnector.kick_from_channel(tool.users_channel, slack_user.slack_id)
  rescue => e
    Service::ErrorReporter.notify(e)
  end

  def checkout_success_message(approved_by: nil)
    slack_id = SlackUser.find_by(member_id: member_id)&.slack_id
    member_reference = slack_id.present? ? "<@#{slack_id}> (#{member.fullname})" : "*#{member.fullname}*"
    approval = approved_by.present? ? " by #{approved_by}" : ''
    message = "#{member_reference} has been checked out on *#{tool.name}* in *#{tool.shop.try(:name)}*#{approval}."
    return message if tool.users_channel.blank?

    users_channel = Service::SlackChannelCache.normalize_name(tool.users_channel)
    if slack_id.blank?
      "#{message}, #{member.fullname} is not yet on Slack, so could not add them to #{users_channel}"
    elsif users_channel_invitation_failed?
      "#{message}, please manually invite <@#{slack_id}> to #{users_channel}"
    else
      message
    end
  end

  def users_channel_invitation_failed?
    @users_channel_invitation_status == :failed
  end

  private

  def complete_revocation_step(step)
    return if Array(revocation_cleanup_completed_steps).include?(step)

    yield
    add_to_set(revocation_cleanup_completed_steps: step)
  end

  def log_revocation_audit
    return if AuditLog.where(event_type: "tool_checkout_revoked", resource_id: id).exists?

    actor = Member.find_by(id: revoked_by_id)
    raise "Missing revocation actor for checkout #{id}" unless actor

    ::Service::AuditLogger.log(
      log_type: "member", event_type: "tool_checkout_revoked", resource_type: "ToolCheckout",
      resource_id: id, actor: actor, subject: member,
      after_snapshot: { tool_id: tool_id.to_s, revocation_reason: revocation_reason,
                        shop_name: tool.shop.name, tool_name: tool.name },
      message_details: "shop: #{tool.shop.name}, tool: #{tool.name}",
      slack_channel: ::Service::SlackConnector.logs_channel
    )
  end

  def currently_approves_tool?(approver)
    approver.role.in?(%w[admin board_member]) || approver.manages_shop?(tool.shop_id) ||
      (!tool.disabled? && approver.valid_for_checkout_request? &&
        CheckoutApprover.find_by(member_id: approver.id)&.can_approve_tool?(tool))
  end

  def revoker_description(revoked_by)
    return "an admin" if revoked_by.role == "admin"
    return "a board member" if revoked_by.role == "board_member"
    return "an RM" if revoked_by.manages_shop?(tool.shop_id)

    "a checkout approver"
  end

  def enqueue_checkout_canvas_sync
    CheckoutCreation.notify do
      ToolCheckoutSlackCanvasSyncJob.perform_later(tool.shop_id.to_s, id.to_s, "add")
    end
  end

  def enqueue_checkout_canvas_sync_after_revocation
    return unless previous_changes.key?("revoked_at") || @completed_revocation_cleanup

    action = revoked_at.present? ? "remove" : "add"
    ToolCheckoutSlackCanvasSyncJob.perform_later(tool.shop_id.to_s, id.to_s, action)
  end

  def close_open_request
    requests = ToolCheckoutRequest.where(member_id: member_id, tool_id: tool_id, status: "open")
    requests = requests.where(id: checkout_request_id) if checkout_request_id
    request = requests.order_by(request_date: :asc, id: :asc).first
    request.update_attributes!(status: "closed", checked_out_id: id) if request
    ToolGroupCheckout.reconcile!(member_id)
  end

  def invite_member_to_users_channel(channel: tool.users_channel)
    @users_channel_invitation_status = :not_configured
    return if channel.blank?

    slack_user = SlackUser.find_by(member_id: member_id)
    if slack_user.nil? || slack_user.slack_id.blank?
      @users_channel_invitation_status = :missing_slack_id
      return
    end

    if ::Service::SlackConnector.channel_member?(channel, slack_user.slack_id)
      @users_channel_invitation_status = :already_member
      return
    end

    ::Service::SlackConnector.invite_to_channel(channel, slack_user.slack_id)
    @users_channel_invitation_status = :invited
  rescue => e
    begin
      # Some Slack client versions expose the endpoint only through the
      # generated conversations_invite method. Retry it with the bot client
      # before asking a human to add the member manually.
      ::Service::SlackConnector.client.conversations_invite(
        channel: channel,
        users: slack_user.slack_id
      )
      @users_channel_invitation_status = :invited
    rescue => fallback_error
      @users_channel_invitation_status = :failed
      Service::ErrorReporter.notify(fallback_error, context: {
        action: 'invite member to tool users channel',
        channel: channel,
        slack_id: slack_user&.slack_id,
        initial_error: e.message
      })
    end
  end
  public :invite_member_to_users_channel
end
