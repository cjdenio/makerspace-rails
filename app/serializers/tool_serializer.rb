class ToolSerializer < ActiveModel::Serializer
  attribute :requestor_annotation
  attributes :open, :id, :name, :wiki_url, :gdrive_id, :description, :disabled, :out_of_service,
             :allow_pending, :announce,
             :announce_channel, :users_channel, :shop_id, :prerequisite_ids, :location_id,
             :reservable, :max_concurrent_reservations, :reservation_horizon_days,
             :minimum_advance_notice_hours, :prohibit_same_day_reservations, :reservation_full_day, :duration_fees, :max_reservation_duration_hours, :reservation_requires_approval,
             :reservation_prerequisite_tool_ids

  attribute :location_name do
    object.location&.name
  end

  attribute :effective_reservation_prerequisite_ids do
    object.effective_reservation_prerequisite_ids
  end

  attribute :wiki_url_override do
    object.wiki_url
  end

  def wiki_url
    return object.effective_wiki_url unless checkout_context

    object.wiki_url.to_s.strip.presence || WikiUrlBuilder.tool_url(checkout_context.shops[object.shop_id.to_s]&.name, object.name)
  end

  attribute :reservation_prerequisite_names do
    checkout_context ? checkout_context.names(object.effective_reservation_prerequisite_ids) : object.reservation_prerequisites.map(&:name)
  end

  attribute :shop_name do
    checkout_context ? checkout_context.shops[object.shop_id.to_s]&.name : object.shop.try(:name)
  end

  # Sensitive (e.g. lock combo) -- only present for privileged members,
  # checkout approvers for this tool, or a member with an active checkout on
  # it. See Tool#notes_visible_to?.
  attribute :notes, if: :notes_visible? do
    object.notes
  end

  def notes_visible?
    checkout_context ? checkout_context.notes_visible?(object) : object.notes_visible_to?(scope)
  end

  attribute :prerequisite_names do
    checkout_context ? checkout_context.names(object.prerequisite_ids) : object.prerequisites.map(&:name)
  end

  attribute :unmet_prerequisite_ids, if: :include_availability? do
    checked_out_tool_ids = checkout_context ? checkout_context.checked_out_tool_ids : ToolCheckout.where(member_id: scope.id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
    object.prerequisite_ids.map(&:to_s).reject { |pid| checked_out_tool_ids.include?(pid) }
  end

  attribute :unmet_prerequisite_names, if: :include_availability? do
    checked_out_ids = checkout_context ? checkout_context.checked_out_tool_ids.to_a : ToolCheckout.where(member_id: scope.id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
    unmet_ids = object.prerequisite_ids.map(&:to_s) - checked_out_ids
    checkout_context ? checkout_context.names(unmet_ids) : Tool.where(:id.in => unmet_ids).map(&:name)
  end

  attribute :requestable, if: :include_availability? do
    !object.open
  end

  def include_availability?
    scope.present?
  end

  def checkout_context
    instance_options[:checkout_context]
  end
end
