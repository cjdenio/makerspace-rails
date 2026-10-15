class ToolCheckoutRequest
  include Mongoid::Document
  include SanitizesUserInput
  include ActiveModel::Serializers::JSON

  field :note, type: String
  field :request_date, type: Time, default: -> { Time.now }
  field :status, type: String, default: "open"
  field :message_id, type: String
  # Set when an approver declines: who, when, and the reason shown to the requester.
  field :decided_by_id, type: BSON::ObjectId
  field :decided_at, type: Time
  field :decision_reason, type: String
  # One entry per "still waiting" post in the Resource Managers channel, keyed
  # by reminder number ("1" at 5 days, "2" at 10 days, ...). reminder_open stays
  # true while a posted reminder still needs its resolution update. See
  # CheckoutRequestReminder.
  field :reminders, type: Hash, default: {}
  field :reminder_open, type: Boolean, default: false

  belongs_to :member
  belongs_to :tool, optional: true
  belongs_to :tool_group, optional: true
  index({ tool_group_id: 1, status: 1 })
  belongs_to :checked_out, class_name: "ToolCheckout", optional: true

  index({ member_id: 1, status: 1, request_date: 1, _id: 1 })
  index({ tool_id: 1, status: 1, request_date: 1, _id: 1 })

  validates :member, presence: true
  validate :exactly_one_target

  def target
    tool_group || tool
  end

  def exactly_one_target
    errors.add(:base, 'Choose exactly one tool or group') unless [tool_id, tool_group_id].count(&:present?) == 1 && target
  end
  validates :status, inclusion: { in: %w[open closed deleted declined] }
  validates :note, length: { maximum: 128 }, allow_blank: true
  validates :decision_reason, length: { maximum: 255 }, allow_blank: true
  validates :decision_reason, presence: true, if: :declined?

  validate :tool_requires_checkout, on: :create

  def tool_requires_checkout
    errors.add(:tool, "No checkout required") if tool&.open
  end

  def open?
    status == "open"
  end

  def declined?
    status == "declined"
  end

  # Declined by the system after the last reminder (no deciding member).
  def timed_out?
    declined? && decided_by_id.nil?
  end

  def days_open_at_decision
    return unless decided_at && request_date

    (decided_at.in_time_zone.to_date - request_date.in_time_zone.to_date).to_i
  end

  def decided_by
    Member.find_by(id: decided_by_id) if decided_by_id
  end

  def self.table_query(criteria, params)
    rows = criteria.to_a
    search = params[:search].to_s.downcase.strip

    if search.present?
      rows = rows.select do |request|
        [
          request.target.try(:name),
          request.target.try(:shop).try(:name),
          request.member.try(:fullname),
          request.member.try(:email),
          request.note
        ].compact.any? { |value| value.to_s.downcase.include?(search) }
      end
    end

    sort_by = params[:order_by].presence || "request_date"
    rows = rows.sort_by { |request| [sortable_value_for(request, sort_by), request.id.to_s] }
    params[:order].to_s.downcase == "desc" ? rows.reverse : rows
  end

  def self.sortable_value_for(request, sort_by)
    case sort_by.to_s
    when "toolName", "tool_name"
      request.target.try(:name).to_s.downcase
    when "shopName", "shop_name"
      request.target.try(:shop).try(:name).to_s.downcase
    when "memberName", "member_name"
      request.member.try(:fullname).to_s.downcase
    when "memberEmail", "member_email"
      request.member.try(:email).to_s.downcase
    when "note"
      request.note.to_s.downcase
    else
      request.request_date || Time.at(0)
    end
  end

  def announce_request
    return unless target.announce?

    channel = target.announce_channel.presence || target.shop.try(:slack_channel)
    return if channel.blank?

    message = "*#{member.fullname}* requested checkout on *#{target.name}* in *#{target.shop.try(:name)}*."
    message += "\n> #{note}" if note.present?
    response = ::Service::SlackConnector.send_slack_message(message, channel)
    if response.respond_to?(:ts)
      timestamp = response.ts
      register_announcement(timestamp)
      # A terminal-state notification may already have run while Slack was
      # sending. Preserve whichever announcement was recorded first and bring
      # that message up to date before removing a redundant late post.
      if status == "deleted"
        ::Service::SlackConnector.update_slack_message(channel, message_id,
          "*#{member.fullname}* cancelled their checkout request for *#{target.name}*.")
      elsif status == "declined"
        ::Service::SlackConnector.update_slack_message(channel, message_id, declined_announcement_message)
      elsif status == "closed" && checked_out
        ::Service::SlackConnector.update_slack_message(channel, message_id, checkout_success_message)
      end
      discard_duplicate_announcement(channel, timestamp)
    end
  rescue => e
    Service::ErrorReporter.notify(e)
  end

  def notify_requestor
    return if member.direct_notifications_suppressed?

    slack_id = member.slack_user&.slack_id
    return if slack_id.blank?

    message = "Your checkout request for #{CheckoutDisplay.escape(target.name)} has been created."
    if tool_group
      message += "\nIncluded tools: #{tool_group.included_tools.map { |child| CheckoutDisplay.escape(child.name) }.join(', ')}"
    end
    annotation = target.effective_requestor_annotation
    message += "\n\n*Annotation for requestors*\n#{CheckoutDisplay.escape(annotation)}" if annotation.present?
    Service::SlackConnector.send_slack_message(message, slack_id)
  end

  # Request and approval sends can overlap. Atomically retain the first recorded
  # timestamp; neither path may overwrite a message already owned by the other.
  def register_announcement(timestamp)
    self.class.collection.find(_id: id, "$or" => [{ message_id: nil }, { message_id: "" }])
      .find_one_and_update({ "$set" => { message_id: timestamp } })
    reload
  end

  def discard_duplicate_announcement(channel, timestamp)
    return if message_id.blank? || message_id == timestamp

    ::Service::SlackConnector.delete_slack_message(channel, timestamp)
  end

  def remove_announcement(notification_snapshot: nil)
    return if message_id.blank?
    return unless notification_snapshot || target

    channel = if notification_snapshot
      notification_snapshot['channel']
    else
      target.announce_channel.presence || target.shop&.slack_channel
    end
    return if channel.blank?
    target_name = notification_snapshot ? notification_snapshot.fetch('name') : target.name

    ::Service::SlackConnector.update_slack_message(
      channel,
      message_id,
      "*#{member.fullname}* cancelled their checkout request for *#{target_name}*."
    )
  rescue => e
    Service::ErrorReporter.notify(e)
  end

  def declined_announcement_message
    who = "*#{CheckoutDisplay.escape(member.fullname)}*"
    tool_name = "*#{CheckoutDisplay.escape(target.name)}*"
    if timed_out?
      return "The checkout request from #{who} for #{tool_name} timed out after #{days_open_at_decision} days " \
             'and was automatically declined.'
    end

    "The checkout request from #{who} for #{tool_name} was declined."
  end

  # Keep the original channel announcement in step with a decline, as
  # remove_announcement does for a cancellation.
  def refresh_declined_announcement
    return unless declined? && message_id.present? && target

    channel = target.announce_channel.presence || target.shop&.slack_channel
    return if channel.blank?

    ::Service::SlackConnector.update_slack_message(channel, message_id, declined_announcement_message)
  rescue => e
    Service::ErrorReporter.notify(e)
  end

  # DM the requester with the decision and the reason. Direct messages are
  # skipped for members whose notification policy disables them or who have no
  # linked Slack account.
  def notify_declined
    return unless declined?
    return if member.direct_notifications_suppressed?

    slack_id = member.slack_user&.slack_id
    return if slack_id.blank?

    request_text = "Your checkout request for *#{CheckoutDisplay.escape(target.name)}* in " \
                   "*#{CheckoutDisplay.escape(target.shop&.name)}*"
    message = if timed_out?
      "#{request_text} was automatically declined because it timed out: no checkout was recorded within " \
        "#{days_open_at_decision} days. If you still need this checkout, please contact the board on Slack or " \
        'visit an open house to see a board member in person. You can also submit a new request.'
    else
      text = "#{request_text} was declined."
      text += "\nReason: #{CheckoutDisplay.escape(decision_reason)}" if decision_reason.present?
      text
    end
    Service::SlackConnector.send_slack_message(message, slack_id)
  rescue => e
    Service::ErrorReporter.notify(e)
  end

  def checkout_success_message(notification_snapshot: nil)
    return checked_out.checkout_success_message unless notification_snapshot || tool_group

    group_name = notification_snapshot ? notification_snapshot.fetch('name') : tool_group.name
    tool_names = if notification_snapshot
      notification_snapshot.fetch('tools').map { |child| child.fetch('name') }
    else
      tool_group.included_tools.map(&:name)
    end
    "*#{CheckoutDisplay.escape(member.fullname)}* has completed checkout for *#{CheckoutDisplay.escape(group_name)}*: " \
      "#{tool_names.map { |name| CheckoutDisplay.escape(name) }.join(', ')}."
  end

  def refresh_closed_announcement(notification_snapshot: nil)
    return unless status == 'closed' && message_id.present? && (notification_snapshot || target)
    channel = if notification_snapshot
      notification_snapshot['channel']
    else
      target.announce_channel.presence || target.shop&.slack_channel
    end
    if channel.present?
      Service::SlackConnector.update_slack_message(channel, message_id,
        checkout_success_message(notification_snapshot: notification_snapshot))
    end
  end
end
