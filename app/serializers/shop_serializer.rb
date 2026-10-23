class ShopSerializer < ActiveModel::Serializer
  attribute :can_generate_checkout_required_sheet do
    CheckoutRequiredSheetPolicy.new(instance_options[:sheet_viewer] || scope).allowed?(object)
  end

  attributes :out_of_service, :out_of_service_note
  attribute :resource_managers do
    batched = checkout_context&.resource_managers_for(object)
    batched || Member.shop_resource_manager_candidates.where(resource_manager_shop_ids: object.id.to_s).map { |m| { id: m.id.to_s, name: m.fullname } }
  end
  attribute :requestor_annotation
  attributes :id, :name, :wiki_url, :gdrive_id, :slack_channel, :disabled, :reservable,
             :max_concurrent_reservations, :reservation_horizon_days,
             :minimum_advance_notice_hours, :prohibit_same_day_reservations, :reservation_full_day, :duration_fees, :max_reservation_duration_hours, :reservation_requires_approval,
             :reservation_prerequisite_tool_ids, :reservation_prerequisite_names,
             :color_id, :google_resource_id, :resource_email, :floor_name, :capacity

  attribute :tool_count do
    checkout_context ? checkout_context.tool_count(object) : object.tools.count
  end

  attribute :wiki_url_override do
    object.wiki_url
  end

  def wiki_url
    object.effective_wiki_url
  end

  def reservable
    return false if scope&.status == 'pending'

    object.reservable
  end

  def reservation_prerequisite_names
    checkout_context ? checkout_context.names(object.reservation_prerequisite_tool_ids) : object.reservation_prerequisites.map(&:name)
  end

  def checkout_context
    instance_options[:checkout_context]
  end
end
