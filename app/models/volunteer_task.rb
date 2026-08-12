class VolunteerTask
  include Mongoid::Document
  include SanitizesUserInput
  include Mongoid::Timestamps
  include Service::SlackConnector

  store_in collection: 'volunteer_tasks'

  # Task details
  field :task_number,  type: Integer               # auto-assigned sequential ID
  field :title,        type: String
  field :description,  type: String
  field :credit_value, type: Float, default: 1.0

  # Optional shop association
  field :shop_id,      type: BSON::ObjectId, default: nil
  field :prerequisite_tool_ids, type: Array, default: []

  # Lifecycle status
  # available  — posted, open for claiming
  # claimed    — a member has claimed it, pending completion
  # pending    — completed by member, awaiting admin/RM verification
  # completed  — verified and credit issued
  # cancelled  — removed from the board
  # denied     — child task (reusable/repeatable/recurring) was rejected/released; terminal
  # reusable   — can be claimed by any member once; original stays untouched, child task created
  # repeatable — like reusable but the same member may claim it multiple times
  # recurring  — like repeatable; also carries a recurrence interval (days field).
  #              Parent status is set to 'claimed' while cooling down, clears on next_available date.
  field :status,         type: String, default: 'available'

  # Recurrence interval in days (recurring tasks only)
  field :days,           type: Integer, default: nil

  # Date after which a recurring task is claimable again (set on the parent)
  field :next_available, type: Date,    default: nil

  # Parent task reference — present on child tasks created for reusable/repeatable/recurring
  field :parent_task_id, type: BSON::ObjectId, default: nil

  field :created_by_id,    type: BSON::ObjectId
  field :claimed_by_id,    type: BSON::ObjectId, default: nil
  field :claimed_at,       type: Time,            default: nil
  field :completed_at,     type: Time,            default: nil
  field :verified_by_id,   type: BSON::ObjectId,  default: nil
  field :rejection_reason, type: String,           default: nil

  SINGLE_USE_STATUSES = %w[available claimed pending completed cancelled denied].freeze
  MULTI_USE_STATUSES  = %w[reusable repeatable recurring].freeze
  VALID_STATUSES      = (SINGLE_USE_STATUSES + MULTI_USE_STATUSES).freeze

  validates :title,        presence: true
  validates :description,  presence: true
  validates :credit_value, numericality: { greater_than: 0 }
  validates_inclusion_of :status, in: VALID_STATUSES
  validates :days, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  validate :days_required_for_recurring
  validate :credit_value_within_max, on: :create
  validate :prerequisites_belong_to_shop

  before_create :assign_task_number

  index({ status: 1 })
  index({ claimed_by_id: 1 })
  index({ parent_task_id: 1 })
  index({ shop_id: 1 })
  index({ task_number: 1 }, { unique: true })

  # ── Scopes ────────────────────────────────────────────────────────────────

  scope :available, -> { where(status: 'available') }
  scope :active,    -> { where(:status.in => %w[available claimed pending reusable repeatable recurring]) }

  # Claimable from the member's perspective — excludes recurring tasks still cooling down
  scope :claimable, -> {
    any_of(
      { :status.in => %w[available reusable repeatable] },
      { status: 'recurring', :next_available.lte => Date.today },
      { status: 'recurring', next_available: nil }
    )
  }

  # ── Settings ──────────────────────────────────────────────────────────────

  def self.max_credit_value
    (SystemConfig.get('volunteer_task_max_credit') ||
      ENV.fetch('VOLUNTEER_TASK_MAX_CREDIT', 2.0)).to_f
  end

  def self.find_by_number(number)
    find_by(task_number: number.to_i)
  end

  # ── Derived Flags ─────────────────────────────────────────────────────────

  def child_task?
    parent_task_id.present?
  end

  def parent_task
    VolunteerTask.find(parent_task_id) if parent_task_id
  end

  def multi_use?
    MULTI_USE_STATUSES.include?(status)
  end

  def currently_cooling_down?
    status == 'recurring' && next_available.present? && next_available > Date.today
  end

  # ── Instance Methods ──────────────────────────────────────────────────────

  def display_number
    "##{task_number}"
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
    return false unless member&.status == "activeMember"
    return true if %w[admin board_member resource_manager].include?(member.role)

    missing_prerequisite_tool_ids(member).empty?
  end

  def created_by
    Member.find(created_by_id) if created_by_id
  end

  def claimed_by
    Member.find(claimed_by_id) if claimed_by_id
  end

  def verified_by
    Member.find(verified_by_id) if verified_by_id
  end

  # Claim a task.
  # Standard tasks: must be status='available'.
  # Reusable:   creates a child task; member may not have an existing child for this parent.
  # Repeatable: creates a child task; same member may claim multiple times.
  # Recurring:  creates a child task; respects next_available cooldown; sets parent claimed_at + status + next_available.
  def claim!(member)
    raise Error::Forbidden.new unless member.status == "activeMember"
    raise Error::Forbidden.new unless eligible_for?(member)

    result = case status
    when 'available'
      update!(status: 'claimed', claimed_by_id: member.id, claimed_at: Time.now)
      self

    when 'reusable'
      already_claimed = VolunteerTask.where(
        parent_task_id: id,
        claimed_by_id:  member.id,
        :status.in      => %w[claimed pending completed]
      ).exists?
      raise Error::AlreadyClaimed.new if already_claimed

      create_child_task!(member)

    when 'repeatable'
      create_child_task!(member)

    when 'recurring'
      raise Error::CoolingDown.new if currently_cooling_down?

      child = create_child_task!(member)
      # Update the parent's cooldown fields
      update!(
        claimed_at:     Time.now,
        status:         'recurring',    # stays recurring; next_available drives visibility
        next_available: Date.today + (days || 1).days
      )
      child

    else
      raise Error::Forbidden.new
    end

    enqueue_volunteer_canvas_sync(struck_task_id: child_task? ? parent_task_id : id)
    result
  end

  def mark_pending!(member)
    raise Error::Forbidden.new unless status == 'claimed' && claimed_by_id == member.id
    update!(status: 'pending', completed_at: Time.now)
  end

  def complete!(verifier)
    raise Error::Forbidden.new if verifier.id == claimed_by_id
    raise Error::Forbidden.new unless status == 'pending'

    update!(status: 'completed', verified_by_id: verifier.id)

    credit = VolunteerCredit.create!(
      member_id:    claimed_by_id,
      issued_by_id: verifier.id,
      task_id:      id,
      description:  "Completed bounty task: #{effective_title}",
      credit_value: credit_value,
      status:       'approved'
    )
    credit.send(:notify_member_credit_awarded)
    credit.send(:check_discount_threshold!)

    notify_task_verified(verifier)
  end

  # Release a claimed task back to available (or deny a child task).
  def release!(admin, reason)
    raise Error::Forbidden.new unless status == 'claimed'
    raise Error::Forbidden.new if admin.id == claimed_by_id

    former_claimant_id = claimed_by_id

    if child_task?
      update!(status: 'denied', rejection_reason: reason)
    else
      update!(
        status:           'available',
        claimed_by_id:    nil,
        claimed_at:       nil,
        rejection_reason: reason
      )
    end

    notify_member_task_released(former_claimant_id, reason)
    enqueue_volunteer_canvas_sync
  end

  # Reject a pending task (or deny a child task).
  def reject_pending!(admin, reason)
    raise Error::Forbidden.new unless status == 'pending'
    raise Error::Forbidden.new if admin.id == claimed_by_id

    former_claimant_id = claimed_by_id

    if child_task?
      update!(status: 'denied', rejection_reason: reason)
    else
      update!(
        status:           'available',
        claimed_by_id:    nil,
        claimed_at:       nil,
        completed_at:     nil,
        rejection_reason: reason
      )
    end

    notify_member_task_rejected(former_claimant_id, reason)
    enqueue_volunteer_canvas_sync
  end

  def cancel!
    update!(status: 'cancelled')
  end

  private

  # Build and save a child task document for multi-use claim patterns.
  def create_child_task!(member)
    child = VolunteerTask.new(
      title:         title,
      description:   description,
      credit_value:  credit_value,
      shop_id:       shop_id,
      prerequisite_tool_ids: Array(prerequisite_tool_ids),
      created_by_id: created_by_id,
      parent_task_id: id,
      status:        'claimed',
      claimed_by_id: member.id,
      claimed_at:    Time.now
    )
    child.save!
    child
  end

  # Use the parent task's title when displaying a child task for notifications.
  def effective_title
    child_task? ? (parent_task&.title || title) : title
  end

  def assign_task_number
    counter_key = 'volunteer_task_counter'
    current     = SystemConfig.get(counter_key).to_i
    next_number = current + 1
    SystemConfig.set(counter_key, next_number.to_s)
    self.task_number = next_number
  end

  def credit_value_within_max
    max = VolunteerTask.max_credit_value
    if credit_value && credit_value > max
      errors.add(:credit_value, "cannot exceed #{max} credits (current maximum). Contact an admin to increase the limit.")
    end
  end

  def days_required_for_recurring
    if status == 'recurring' && days.blank?
      errors.add(:days, 'must be set for recurring tasks')
    end
  end

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

  def enqueue_volunteer_canvas_sync(struck_task_id: nil)
    effective_shop_id = shop_id || parent_task&.shop_id
    return if effective_shop_id.blank?

    VolunteerSlackCanvasSyncJob.perform_later(
      effective_shop_id.to_s,
      struck_task_id&.to_s
    )
  rescue => error
    Rails.logger.error(
      "[VolunteerSlackCanvasEnqueueError] task_id=#{id} error=#{error.class}: #{error.message}"
    )
    Honeybadger.notify(error) if defined?(Honeybadger)
  end

  def notify_task_verified(verifier)
    claimant      = Member.find(claimed_by_id) rescue nil
    claimant_name = claimant&.fullname || 'Unknown member'

    ::Service::SlackConnector.send_slack_message(
      "✅ *#{verifier.fullname}* verified task *#{effective_title}* (#{display_number}) " \
      "complete for *#{claimant_name}*. Credit issued!",
      VolunteerCredit.pending_slack_channel
    )
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end

  def notify_member_task_released(member_id, reason)
    slack_user = SlackUser.find_by(member_id: member_id)
    return unless slack_user

    ::Service::SlackConnector.send_slack_message(
      "ℹ️ Your claim on *#{effective_title}* (#{display_number}) has been released by an admin. " \
      "Reason: #{reason}. The task is now available for others to claim.",
      slack_user.slack_id
    )
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end

  def notify_member_task_rejected(member_id, reason)
    slack_user = SlackUser.find_by(member_id: member_id)
    return unless slack_user

    ::Service::SlackConnector.send_slack_message(
      "ℹ️ Your completion of *#{effective_title}* (#{display_number}) was not verified. " \
      "Reason: #{reason}. The task is now available for reclaiming.",
      slack_user.slack_id
    )
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end
end
