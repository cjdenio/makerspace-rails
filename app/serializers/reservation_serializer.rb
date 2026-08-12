class ReservationSerializer < ActiveModel::Serializer
  attributes :id, :title, :member_id, :member_name, :shop_id, :shop_name,
             :reservation_scope, :tool_ids, :tool_names, :start_at, :end_at,
             :status, :approval_reasons, :decision_note, :decided_by_id,
             :decided_by_name, :decided_at, :source, :calendar_event_id,
             :calendar_html_link, :calendar_sync_status, :calendar_synced_at,
             :created_at, :updated_at

  attribute :approval_details do
    object.effective_approval_details
  end

  attribute :calendar_sync_error, if: :manager_view?

  def member_name
    object.member.try(:fullname)
  end

  def shop_name
    object.shop.try(:name)
  end

  def tool_names
    object.tools.map(&:name)
  end

  def decided_by_name
    object.decided_by.try(:fullname)
  end

  def manager_view?
    return false unless scope
    scope.role.in?(%w[admin board_member]) || scope.manages_shop?(object.shop_id)
  end
end
