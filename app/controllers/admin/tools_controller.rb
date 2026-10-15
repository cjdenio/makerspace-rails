class Admin::ToolsController < ApplicationController
  before_action :authenticate_member!
  before_action :authorize_index, only: [:index]
  before_action :find_tool, only: [:update, :destroy, :notes, :requestor_annotation]
  before_action :authorize_create, only: [:create]
  before_action :authorize_manage, only: [:update, :destroy]
  before_action :authorize_notes, only: [:notes]
  before_action :authorize_annotation, only: [:requestor_annotation]
  before_action :prevent_move_with_active_reservations, only: [:update]
  around_action :lock_catalog_mutation, only: [:create, :update, :destroy]

  def index
    tools = params[:shop_id] ? Tool.where(shop_id: params[:shop_id]) : Tool.all
    unless is_admin? || is_board_member?
      ordinary_ids = current_member.valid_for_checkout_request? ?
        CheckoutApprover.allowed_tool_ids_for_member(current_member.id) : []
      tools = tools.any_of(
        { :shop_id.in => managed_shop_ids },
        { :id.in => ordinary_ids, :disabled.ne => true }
      )
    end
    tools = tools.order_by(name: :asc).to_a
    render json: tools,
      each_serializer: AdminToolSerializer,
      adapter: :attributes,
      scope: current_member,
      checkout_context: CheckoutReadContext.for_tools(tools, current_member),
      management_shop_ids: managed_shop_ids,
      global_management: is_admin? || is_board_member?
  end

  def create
    attributes = tool_params
    resolved_channels = resolve_changed_slack_channels(attributes, nil, current_member)
    tool = Tool.new(attributes)
    tool.save!
    Service::SlackChannelAssignment.invite_bot_or_notify(resolved_channels, current_member)
    GoogleResourceSyncJob.perform_later("Tool", tool.id.to_s)

    ::Service::AuditLogger.log(
      log_type:       'portal',
      event_type:     'tool_created',
      resource_type:  'Tool',
      resource_id:    tool.id,
      actor:          current_member,
      after_snapshot: tool.attributes
    )

    render json: tool, serializer: ToolSerializer, adapter: :attributes, scope: current_member
  end

  def update
    attributes = tool_params
    resolved_channels = resolve_changed_slack_channels(attributes, @tool, current_member)
    before = @tool.attributes.dup
    @tool.update_attributes!(attributes)
    cleanup_vacated_tool_marker(before['location_id'])
    Service::SlackChannelAssignment.invite_bot_or_notify(resolved_channels, current_member)
    if @tool.resource_email.blank? || @tool.previous_changes.key?("name") || @tool.previous_changes.key?("reservable")
      GoogleResourceSyncJob.perform_later("Tool", @tool.id.to_s)
    end

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'tool_updated',
      resource_type:   'Tool',
      resource_id:     @tool.id,
      actor:           current_member,
      field_changes:   @tool.previous_changes,
      before_snapshot: before,
      after_snapshot:  @tool.attributes
    )

    render json: @tool, serializer: ToolSerializer, adapter: :attributes, scope: current_member
  end

  # Separate from #update: any checkout approver for this tool may set the
  # notes (e.g. lock combo), not just shop managers/admins -- see #189.
  def notes
    before = @tool.notes
    @tool.update_attributes!(notes: params[:notes])

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'tool_notes_updated',
      resource_type:   'Tool',
      resource_id:     @tool.id,
      actor:           current_member,
      field_changes:   { 'notes' => [before, @tool.notes] }
    )

    render json: @tool, serializer: ToolSerializer, adapter: :attributes, scope: current_member
  end

  def requestor_annotation
    before = @tool.requestor_annotation
    @tool.update_attributes!(params.permit(:requestor_annotation))
    ::Service::AuditLogger.log(
      log_type: 'portal', event_type: 'tool_requestor_annotation_updated',
      resource_type: 'Tool', resource_id: @tool.id, actor: current_member,
      field_changes: { 'requestor_annotation' => [before, @tool.requestor_annotation] }
    )
    render json: @tool, serializer: ToolSerializer, adapter: :attributes, scope: current_member
  end

  def destroy
    prevent_ticket_reference_change!
    if current_or_future_blocking_reservations.exists?
      raise ::Error::Conflict.new("Cancel future reservations before deleting this tool")
    end
    prevent_deletion_if_prerequisite_is_referenced
    before = @tool.attributes.dup
    google_resource_id = @tool.google_resource_id
    label_source_id = @tool.id.to_s
    @tool.destroy
    GoogleResourceDeleteJob.perform_later(google_resource_id, label_source_id)
    CheckoutApprover.where(:tool_ids.in => [before["_id"].to_s]).each do |approver|
      approver.pull(tool_ids: before["_id"].to_s)
      approver.destroy if approver.shop_ids.blank? && approver.tool_ids.blank?
    end

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'tool_deleted',
      resource_type:   'Tool',
      resource_id:     before['_id'],
      actor:           current_member,
      before_snapshot: before,
      after_snapshot:  {}
    )

    render json: {}, status: 204
  end

  private

  def lock_catalog_mutation(&block)
    CatalogMutationLock.with([@tool&.shop_id, params[:shop_id]], &block)
  end

  # When a tool moves to a different location, its old marker -- if it only
  # ever existed to hold this one tool -- is now dead weight. Without this,
  # reassigning a tool left its previous marker behind as an orphaned shell
  # (same name, no tool link, indistinguishable from a real location at a
  # glance): confirmed in production as a real way to accumulate duplicate-
  # looking "Bambu X1C"-style markers. Only removes a marker that holds
  # nothing else -- no children, no other tools -- so a shared or
  # deliberately-kept location is never touched.
  def cleanup_vacated_tool_marker(old_location_id)
    return if old_location_id.blank? || old_location_id == @tool.location_id
    old_location = Location.where(id: old_location_id).first
    return unless old_location
    return if old_location.children.exists? || old_location.tools.exists?
    old_location.destroy
  end

  def tool_params
    params.permit(:open, :name, :requestor_annotation, :wiki_url, :gdrive_id, :description, :notes, :shop_id, :disabled, :announce,
      :announce_channel, :users_channel, :reservable, :allow_pending, :location_id,
      :max_concurrent_reservations, :reservation_horizon_days,
      :minimum_advance_notice_hours, :prohibit_same_day_reservations, :reservation_full_day, :max_reservation_duration_hours, :reservation_requires_approval,
      prerequisite_ids: [], duration_fees: [:invoice_option_id, :minimum_hours, :maximum_hours, :full_day], reservation_prerequisite_tool_ids: [])
  end

  def resolve_changed_slack_channels(attributes, tool = nil, actor = nil)
    channels = %i[announce_channel users_channel].each_with_object({}) do |field, changed|
      next unless attributes.key?(field)

      normalized = Service::SlackChannelCache.normalize_name(attributes[field])
      next if normalized.blank? || normalized == tool&.public_send(field)

      changed[field] = normalized
    end
    Service::SlackChannelAssignment.resolve!(channels, actor)
  end

  def find_tool
    @tool = Tool.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Tool, { id: params[:id] }) if @tool.nil?
  end

  def authorize_index
    unless is_admin? || is_board_member? || managed_shop_ids.present? || is_valid_checkout_approver?
      raise ::Error::Forbidden.new("User is not privileged or a checkout approver")
    end
  end

  def authorize_create
    shop = Shop.find(tool_params[:shop_id])
    raise ::Error::Forbidden.new("User cannot manage this shop") unless can_manage_shop?(shop)
  end

  def authorize_notes
    raise ::Error::Forbidden.new("User is not authorized to set notes for this tool") unless can_approve_checkout_for_tool?(@tool)
  end

  def authorize_annotation
    raise ::Error::Forbidden.new("User cannot edit this tool's requestor annotation") unless can_approve_checkout_for_tool?(@tool)
  end

  def authorize_manage
    raise ::Error::Forbidden.new("User cannot manage this shop") unless can_manage_shop?(@tool.shop_id)

    target_shop_id = tool_params[:shop_id].presence
    if target_shop_id && !can_manage_shop?(target_shop_id)
      raise ::Error::Forbidden.new("User cannot move this tool to that shop")
    end
  end

  def prevent_move_with_active_reservations
    return unless tool_params.key?(:shop_id)
    return if tool_params[:shop_id].to_s == @tool.shop_id.to_s
    prevent_ticket_reference_change!
    return unless current_or_future_blocking_reservations.exists?

    raise ::Error::Conflict.new(
      "Cancel current and future reservations before moving this tool"
    )
  end

  def current_or_future_blocking_reservations
    Reservation.blocking.where(
      tool_ids: @tool.id.to_s,
      :end_at.gt => Time.current
    )
  end

  def prevent_ticket_reference_change!
    if FixTicket.where(tool_id: @tool.id).exists?
      raise ::Error::Conflict.new('Cannot move or delete a tool referenced by a repair ticket')
    end
  end

  def prevent_deletion_if_prerequisite_is_referenced
    prerequisite_ids = [@tool.id, @tool.id.to_s]
    other_tools = Tool.where(:id.ne => @tool.id)
    checkout_tools = other_tools.where(:prerequisite_ids.in => prerequisite_ids).to_a
    reservation_tools = other_tools.where(
      :reservation_prerequisite_tool_ids.in => prerequisite_ids
    ).to_a
    reservation_shops = Shop.where(
      :reservation_prerequisite_tool_ids.in => prerequisite_ids
    ).to_a
    volunteer_tasks = VolunteerTask.where(
      :prerequisite_tool_ids.in => prerequisite_ids
    ).to_a
    volunteer_events = VolunteerEvent.where(
      :prerequisite_tool_ids.in => prerequisite_ids
    ).to_a

    referenced_records = checkout_tools + reservation_tools + reservation_shops +
      volunteer_tasks + volunteer_events
    return if referenced_records.empty?
    if force_deletion?
      remove_prerequisite_ids(checkout_tools, :prerequisite_ids, prerequisite_ids)
      remove_prerequisite_ids(reservation_tools, :reservation_prerequisite_tool_ids, prerequisite_ids)
      remove_prerequisite_ids(reservation_shops, :reservation_prerequisite_tool_ids, prerequisite_ids)
      remove_prerequisite_ids(volunteer_tasks, :prerequisite_tool_ids, prerequisite_ids)
      remove_prerequisite_ids(volunteer_events, :prerequisite_tool_ids, prerequisite_ids)
      return
    end

    references = []
    references << "checkout prerequisite for tools: #{checkout_tools.map(&:name).join(', ')}" if checkout_tools.any?
    references << "reservation prerequisite for tools: #{reservation_tools.map(&:name).join(', ')}" if reservation_tools.any?
    references << "reservation prerequisite for shops: #{reservation_shops.map(&:name).join(', ')}" if reservation_shops.any?
    references << "volunteer prerequisite for tasks: #{volunteer_tasks.map(&:title).join(', ')}" if volunteer_tasks.any?
    references << "volunteer prerequisite for events: #{volunteer_events.map(&:title).join(', ')}" if volunteer_events.any?

    raise ::Error::Conflict.new(
      "Cannot delete #{@tool.name}; it is a #{references.join('; ')}"
    )
  end

  def force_deletion?
    return false unless ActiveModel::Type::Boolean.new.cast(params[:force])
    raise ::Error::Forbidden.new("Only admins and board members can force delete prerequisites") unless is_admin? || is_board_member?

    true
  end

  def remove_prerequisite_ids(records, field, removed_ids)
    removed_ids = removed_ids.map(&:to_s)
    records.each do |record|
      record.set(field => Array(record.public_send(field)).reject { |id| removed_ids.include?(id.to_s) })
    end
  end
end
