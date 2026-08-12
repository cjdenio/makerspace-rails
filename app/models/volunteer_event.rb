class VolunteerEvent
  include Mongoid::Document
  include SanitizesUserInput
  include Mongoid::Timestamps
  include Service::SlackConnector

  store_in collection: 'volunteer_events'

  field :event_number,      type: Integer
  field :title,             type: String
  field :description,       type: String
  field :credit_value,      type: Float,   default: 1.0
  field :event_date,        type: Date
  field :shop_id,           type: BSON::ObjectId, default: nil
  field :prerequisite_tool_ids, type: Array, default: []
  field :status,            type: String,  default: 'open'  # open | closed
  field :created_by_id,     type: BSON::ObjectId
  field :closed_by_id,      type: BSON::ObjectId, default: nil
  field :closed_at,         type: Time,           default: nil
  field :attendee_ids,      type: Array,          default: []

  # Audit trail for check-in removals.
  field :attendee_removals, type: Array, default: []

  VALID_STATUSES = %w[open closed].freeze

  validates :title,        presence: true
  validates :credit_value, numericality: { greater_than: 0 }
  validates_inclusion_of :status, in: VALID_STATUSES
  validate :prerequisites_belong_to_shop

  before_create :assign_event_number

  index({ status: 1 })
  index({ event_number: 1 }, { unique: true })
  index({ shop_id: 1 })

  scope :active_events, -> { where(status: 'open') }
  scope :closed_events, -> { where(status: 'closed') }

  def self.find_by_number(number)
    find_by(event_number: number.to_i)
  end

  def display_number
    "E#{event_number}"
  end

  def attendee_count
    attendee_ids.length
  end

  def shop
    Shop.find(shop_id) if shop_id
  end

  def prerequisite_tools
    ids = Array(prerequisite_tool_ids).map(&:to_s).uniq
    ids.present? ? Tool.where(:id.in => ids) : Tool.none
  end

  def missing_prerequisite_tools(member)
    Tool.where(:id.in => missing_prerequisite_tool_ids(member)).to_a
  end

  def missing_prerequisite_tool_ids(member)
    required_ids = Array(prerequisite_tool_ids).map(&:to_s).uniq
    return [] if required_ids.empty?

    checked_out_ids = ToolCheckout.where(
      member_id: member.id,
      revoked_at: nil,
      :tool_id.in => required_ids
    ).pluck(:tool_id).map(&:to_s)
    required_ids - checked_out_ids
  end

  def missing_prerequisite_tool_names(member)
    tools_by_id = missing_prerequisite_tools(member).index_by { |tool| tool.id.to_s }
    missing_prerequisite_tool_ids(member).map do |tool_id|
      tools_by_id[tool_id]&.name || "Unavailable tool (#{tool_id})"
    end
  end

  def eligible_for?(member)
    return false unless member&.active_membership_status?
    return true if %w[admin board_member resource_manager].include?(member.role)

    missing_prerequisite_tool_ids(member).empty?
  end

  def created_by
    Member.find(created_by_id) if created_by_id
  end

  def closed_by
    Member.find(closed_by_id) if closed_by_id
  end

  def attendee_names
    return [] if attendee_ids.empty?
    Member.in(id: attendee_ids).map(&:fullname)
  rescue
    []
  end

  # Member self check-in.
  # Guards: event must be open, member must be activeMember, not already checked in.
  def checkin!(member)
    raise Error::Forbidden.new unless status == 'open'
    raise Error::Forbidden.new unless member.active_membership_status?
    raise Error::Forbidden.new unless eligible_for?(member)
    raise Error::Forbidden.new if attendee_ids.include?(member.id)
    push(attendee_ids: member.id)
    notify_member_checkin(member)
  end

  def add_attendee!(member, _added_by)
    raise Error::Forbidden.new unless status == 'open'
    raise Error::Forbidden.new unless eligible_for?(member)
    raise Error::Forbidden.new if attendee_ids.include?(member.id)

    push(attendee_ids: member.id)
    notify_member_checkin(member)
  end

  # Remove a check-in. Works for both member self-removal and admin removal.
  def remove_attendee!(member, removed_by)
    raise Error::Forbidden.new unless status == 'open'
    raise Error::Forbidden.new unless attendee_ids.include?(member.id)

    pull(attendee_ids: member.id)

    push(attendee_removals: {
      'member_id'    => member.id,
      'removed_by_id' => removed_by.id,
      'removed_at'   => Time.now
    })

    # DM the member only when an admin/RM removed them (not self-removal)
    if removed_by.id != member.id
      notify_member_checkin_removed(member, removed_by)
    end
  end

  # Close event and issue credits to all attendees.
  def close!(closed_by_member)
    raise Error::Forbidden.new unless status == 'open'

    update!(
      status:    'closed',
      closed_by_id: closed_by_member.id,
      closed_at: Time.now
    )

    attendee_ids.each do |member_id|
      member = Member.find(member_id) rescue nil
      next if member.nil?
      next unless member.active_membership_status?

      credit = VolunteerCredit.create!(
        member_id:    member_id,
        issued_by_id: closed_by_member.id,
        description:  "Attended event: #{title} (#{display_number})",
        credit_value: credit_value,
        status:       'approved'
      )
      credit.send(:notify_member_credit_awarded)
      credit.send(:check_discount_threshold!)
    rescue => e
      Honeybadger.notify(e) if defined?(Honeybadger)
    end
  end

  private

  def prerequisites_belong_to_shop
    ids = Array(prerequisite_tool_ids).map(&:to_s).reject(&:blank?).uniq
    return if ids.empty?

    if shop_id.blank?
      errors.add(:prerequisite_tool_ids, 'require an associated shop')
      return
    end

    valid_ids = Tool.where(shop_id: shop_id, :id.in => ids).pluck(:id).map(&:to_s)
    errors.add(:prerequisite_tool_ids, 'must belong to the associated shop') unless (ids - valid_ids).empty?
  end

  def assign_event_number
    counter_key = 'volunteer_event_counter'
    current     = SystemConfig.get(counter_key).to_i
    next_number = current + 1
    SystemConfig.set(counter_key, next_number.to_s)
    self.event_number = next_number
  end

  def notify_member_checkin(member)
    slack_user = SlackUser.find_by(member_id: member.id)
    return unless slack_user
    ::Service::SlackConnector.send_slack_message(
      "✅ You're checked in to *#{title}* (#{display_number}). Credits will be issued when the event closes.",
      slack_user.slack_id
    )
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end

  def notify_member_checkin_removed(member, removed_by)
    slack_user = SlackUser.find_by(member_id: member.id)
    return unless slack_user
    ::Service::SlackConnector.send_slack_message(
      "ℹ️ Your check-in for *#{title}* (#{display_number}) was removed by #{removed_by.fullname}. " \
      "Contact an admin if you believe this was an error.",
      slack_user.slack_id
    )
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end
end
