class CheckoutApprover
  include Mongoid::Document
  include ActiveModel::Serializers::JSON

  belongs_to :member

  index({ member_id: 1 })

  # Array of Shop IDs this approver can sign off checkouts for
  field :shop_ids, type: Array, default: []
  # Optional individual Tool IDs. Shop assignments and tool assignments are additive.
  field :tool_ids, type: Array, default: []
  field :tool_group_ids, type: Array, default: []
  field :group_granted_tool_ids, type: Array, default: []
  before_validation :expand_group_authority
  validate :valid_group_assignments

  def can_approve_group?(group)
    group && (can_approve_for_shop?(group.shop_id) || Array(tool_group_ids).map(&:to_s).include?(group.id.to_s))
  end

  validates :member, presence: true
  validate :has_assignment
  validate :assignments_exist

  def shops
    shop_ids.present? ? Shop.where(:id.in => shop_ids) : []
  end

  def tools
    tool_ids.present? ? Tool.where(:id.in => tool_ids) : Tool.none
  end

  # Check if this approver can approve for a given shop
  def can_approve_for_shop?(shop_id)
    shop_ids.map(&:to_s).include?(shop_id.to_s)
  end

  def can_approve_tool?(tool)
    return false if tool.nil?
    can_approve_for_shop?(tool.shop_id) ||
      Array(tool_ids).map(&:to_s).include?(tool.id.to_s)
  end

  # Check if a member is a checkout approver (any shop)
  def self.is_approver?(member_id)
    exists?(member_id: member_id)
  end

  # Get shops a member can approve for
  def self.shops_for_member(member_id)
    approver = find_by(member_id: member_id)
    approver ? approver.shops : []
  end

  def self.tool_ids_for_member(member_id)
    approver = find_by(member_id: member_id)
    approver ? Array(approver.tool_ids) : []
  end

  def self.allowed_tool_ids_for_member(member_id)
    approver = find_by(member_id: member_id)
    return [] unless approver

    shop_tool_ids = Tool.where(:shop_id.in => Array(approver.shop_ids)).pluck(:id)
    (shop_tool_ids + Array(approver.tool_ids)).map(&:to_s).uniq
  end

  private

  def expand_group_authority
    groups = ToolGroup.where(:id.in => Array(tool_group_ids)).to_a
    revoked = ToolCheckout.where(member_id: member_id, :revoked_at.ne => nil).pluck(:tool_id).map(&:to_s)
    if groups.any? { |group| (group.included_tool_ids & revoked).any? }
      errors.add(:tool_group_ids, 'cannot include a group with a revoked checkout')
      return
    end
    self.group_granted_tool_ids = (Array(group_granted_tool_ids) + groups.flat_map(&:included_tool_ids)).uniq
    self.tool_ids = (Array(tool_ids).map(&:to_s) + group_granted_tool_ids).uniq
  end

  def valid_group_assignments
    if ToolGroup.where(:id.in => Array(tool_group_ids), archived: false).count != Array(tool_group_ids).uniq.length
      errors.add(:tool_group_ids, 'contain an invalid group')
    end
  end

  def has_assignment
    return if Array(shop_ids).present? || Array(tool_ids).present?
    errors.add(:base, "At least one shop or tool assignment is required")
  end

  def assignments_exist
    shops_requested = Array(shop_ids).map(&:to_s).uniq
    tools_requested = Array(tool_ids).map(&:to_s).uniq
    valid_shops = Shop.where(:id.in => shops_requested).pluck(:id).map(&:to_s)
    valid_tools = Tool.where(:id.in => tools_requested).pluck(:id).map(&:to_s)
    errors.add(:shop_ids, "contain an invalid shop") unless (shops_requested - valid_shops).empty?
    errors.add(:tool_ids, "contain an invalid tool") unless (tools_requested - valid_tools).empty?
  end
end
