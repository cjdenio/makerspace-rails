class CheckoutApproverRequest
  # The latest constituent checkout is when the complete group became held.
  def checkout_completed_on
    ids = tool_group ? tool_group.included_tool_ids : [tool_id.to_s]
    rows = ToolCheckout.where(member_id: member_id, :tool_id.in => ids, revoked_at: nil).to_a
    return 'Unknown' if ids.empty? || (ids - rows.map { |row| row.tool_id.to_s }).any?
    rows.map(&:checked_out_at).compact.max&.to_date&.iso8601 || 'Unknown'
  end

  include Mongoid::Document

  belongs_to :member
  belongs_to :tool, optional: true
  belongs_to :tool_group, optional: true

  field :status, type: String, default: "open"
  field :request_date, type: Time, default: -> { Time.current }
  field :note, type: String
  field :decision_note, type: String
  field :decided_at, type: Time

  index({ member_id: 1, tool_id: 1, tool_group_id: 1, status: 1 }, unique: true,
    partial_filter_expression: { status: "open" })

  validates :member, presence: true
  validate :exactly_one_target

  def target
    tool_group || tool
  end

  def exactly_one_target
    errors.add(:base, 'Choose exactly one tool or group') unless [tool_id, tool_group_id].count(&:present?) == 1 && target
  end
  validates :status, inclusion: { in: %w[open approved declined revoked] }
  validates :note, :decision_note, length: { maximum: 128 }, allow_blank: true
  validate :member_has_active_checkout, on: :create
  validate :member_is_eligible, on: :create
  validate :request_is_not_duplicate, on: :create

  def open?
    status == "open"
  end

  private

  def member_has_active_checkout
    if tool_group
      active = ToolCheckout.where(member_id: member_id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
      errors.add(:member, 'must have every included checkout') unless (tool_group.included_tool_ids - active).empty?
      return
    end
    errors.add(:member, "must have an active checkout for this tool") unless
      member && tool && ToolCheckout.where(member_id: member.id, tool_id: tool.id, revoked_at: nil).exists?
  end

  def member_is_eligible
    errors.add(:member, "must be in good standing") unless member&.valid_for_checkout_request?
  end

  def request_is_not_duplicate
    errors.add(:base, "A volunteer request is already open") if
      self.class.where(member_id: member_id, tool_id: tool_id, tool_group_id: tool_group_id, status: "open").exists?
  end
end
