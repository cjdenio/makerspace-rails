class ToolSerializer < ActiveModel::Serializer
  attributes :id, :name, :wiki_url, :gdrive_id, :description, :disabled,
             :allow_pending, :announce,
             :announce_channel, :users_channel, :shop_id, :prerequisite_ids,
             :reservable, :max_concurrent_reservations, :reservation_horizon_days,
             :max_reservation_duration_hours, :reservation_requires_approval,
             :reservation_prerequisite_tool_ids

  attribute :effective_reservation_prerequisite_ids do
    object.effective_reservation_prerequisite_ids
  end

  attribute :wiki_url_override do
    object.wiki_url
  end

  def wiki_url
    object.effective_wiki_url
  end

  attribute :reservation_prerequisite_names do
    object.reservation_prerequisites.map(&:name)
  end

  attribute :shop_name do
    object.shop.try(:name)
  end

  attribute :prerequisite_names do
    object.prerequisites.map(&:name)
  end

  attribute :unmet_prerequisite_ids, if: :include_availability? do
    checked_out_tool_ids = ToolCheckout.where(member_id: scope.id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
    object.prerequisite_ids.map(&:to_s).reject { |pid| checked_out_tool_ids.include?(pid) }
  end

  attribute :unmet_prerequisite_names, if: :include_availability? do
    unmet_ids = object.prerequisite_ids.map(&:to_s) - ToolCheckout.where(member_id: scope.id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
    Tool.where(:id.in => unmet_ids).map(&:name)
  end

  attribute :requestable, if: :include_availability? do
    true
  end

  def include_availability?
    scope.present?
  end
end
