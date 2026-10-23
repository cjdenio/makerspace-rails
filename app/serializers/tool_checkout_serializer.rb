class ToolCheckoutSerializer < ActiveModel::Serializer
  attributes :expires_on, :expiration_revision, :expiration_status, :checkout_training_plan_url, :renewed_from_id, :superseded_by_id
  attribute(:can_manage_expiration) { object.current_checkout? && ToolGroup.manageable_by?(scope, checkout_tool&.shop_id) }
  attribute(:can_renew) { !!(scope && checkout_tool && object.member_id == scope.id && object.current_checkout? && object.expired? && ToolCheckoutRequestEligibility.new(member: scope, tool: checkout_tool).eligible?) }
  attributes :group_id, :group_revision, :group_name, :approval_batch_id, :reinstated_from_id
  attribute :out_of_service do
    !!object.tool&.out_of_service
  end
  attributes :id, :member_id, :tool_id, :checked_out_at, :revoked_at,
             :signed_off_via, :approved_by_id

  # Derived, never stored on the revoked row: a revoked checkout that an
  # active checkout supersedes (a reinstatement) and the superseding record.
  attribute :reinstated do
    reinstated_by_checkout_id.present?
  end

  attribute :reinstated_by_checkout_id do
    reinstated_by_checkout_id
  end

  # Internal notes and who/when. Present only for approvers of the tool, RMs
  # of its shop, board members and admins, and never for the checkout's own
  # member (so a member never sees why they were revoked, even when they are
  # also an approver) or for other members.
  with_options(if: :internal_notes_visible?) do
    attribute(:revocation_reason) { object.revocation_reason }
    attribute(:request_note) { object.request_note }
    attribute(:revoked_by_id) { object.revoked_by_id }
    attribute(:revoked_by_name) { checkout_member_name(object.revoked_by_id) }
    attribute(:reinstatement_reason) { object.reinstatement_reason }
    attribute(:reinstated_by_id) { object.reinstated_by_id }
    attribute(:reinstated_by_name) { checkout_member_name(object.reinstated_by_id) }
    attribute(:reinstated_at) { object.reinstated_at }
  end

  attribute :tool_name do
    checkout_tool.try(:name)
  end

  attribute :shop_name do
    checkout_shop.try(:name)
  end

  attribute :shop_id do
    checkout_tool.try(:shop_id)
  end

  attribute :shop_wiki_url do
    checkout_shop.try(:effective_wiki_url)
  end

  attribute :member_name do
    checkout_member.try(:fullname)
  end

  attribute :member_email do
    checkout_member.try(:email)
  end

  attribute :approved_by_name do
    checkout_approved_by.try(:fullname)
  end

  attribute :active do
    object.active?
  end

  # Sensitive (e.g. lock combo) -- only present when the viewer is entitled
  # per Tool#notes_visible_to? (an active, approved checkout holder, a
  # checkout approver for the tool, or a privileged member). An open,
  # not-yet-approved request or a revoked checkout does not qualify.
  attribute :tool_notes, if: :tool_notes_visible? do
    checkout_tool.notes
  end

  def checkout_training_plan_url
    return object.checkout_training_plan_url unless checkout_context
    checkout_tool&.checkout_training_plan_url.presence || checkout_context.tool_groups[object.group_id.to_s]&.checkout_training_plan_url
  end

  def tool_notes_visible?
    checkout_tool.present? && (checkout_context ? checkout_context.notes_visible?(checkout_tool) : checkout_tool.notes_visible_to?(scope))
  end

  def internal_notes_visible?
    return false if scope.nil? || object.member_id == scope.id || checkout_tool.blank?

    if checkout_context
      checkout_context.internal_notes_visible?(checkout_tool)
    else
      scope.role.in?(%w[admin board_member]) || scope.manages_shop?(checkout_tool.shop_id) ||
        !!CheckoutApprover.find_by(member_id: scope.id)&.can_approve_tool?(checkout_tool)
    end
  end

  def reinstated_by_checkout_id
    return nil if object.revoked_at.nil?
    return @reinstated_by_checkout_id if defined?(@reinstated_by_checkout_id)

    @reinstated_by_checkout_id = if checkout_context
      checkout_context.reinstated_by[object.id.to_s]
    else
      ToolCheckout.reinstated_checkout_ids([object.id])[object.id.to_s]
    end
  end

  def checkout_member_name(id)
    return nil if id.blank?

    (checkout_context ? checkout_context.members[id.to_s] : Member.find_by(id: id)).try(:fullname)
  end

  def checkout_context
    instance_options[:checkout_context]
  end

  def checkout_tool
    checkout_context ? checkout_context.tools[object.tool_id.to_s] : object.tool
  end

  def checkout_shop
    checkout_context ? checkout_context.shops[checkout_tool&.shop_id.to_s] : checkout_tool.try(:shop)
  end

  def checkout_member
    checkout_context ? checkout_context.members[object.member_id.to_s] : object.member
  end

  def checkout_approved_by
    checkout_context ? checkout_context.members[object.approved_by_id.to_s] : object.approved_by
  end
end
