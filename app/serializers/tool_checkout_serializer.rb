class ToolCheckoutSerializer < ActiveModel::Serializer
  attributes :group_id, :group_revision, :group_name, :approval_batch_id
  attribute :out_of_service do
    !!object.tool&.out_of_service
  end
  attributes :id, :member_id, :tool_id, :checked_out_at, :revoked_at,
             :revocation_reason, :signed_off_via, :approved_by_id

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

  def tool_notes_visible?
    checkout_tool.present? && (checkout_context ? checkout_context.notes_visible?(checkout_tool) : checkout_tool.notes_visible_to?(scope))
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
