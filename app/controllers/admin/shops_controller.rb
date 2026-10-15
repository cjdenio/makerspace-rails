class Admin::ShopsController < ApplicationController
  before_action :authenticate_member!
  before_action :authorize_index, only: [:index]
  before_action :authorize_create_destroy, only: [:create, :destroy, :resource_manager_options]

  def resource_manager_options
    render json: Member.shop_resource_manager_candidates.order_by(firstname: :asc).map { |m| { id: m.id.to_s, name: m.fullname } }
  end
  before_action :find_shop, only: [:update, :destroy, :requestor_annotation]
  before_action :authorize_update, only: [:update, :requestor_annotation]

  def index
    shops = if is_admin? || is_board_member?
      Shop.all
    else
      Shop.where(:id.in => managed_shop_ids)
    end
    shops = shops.order_by(name: :asc).to_a
    render json: shops, each_serializer: ShopSerializer, adapter: :attributes, sheet_viewer: current_member,
      checkout_context: CheckoutReadContext.for_shops(shops)
  end

  def create
    manager_ids = resource_manager_ids_param
    attributes = shop_params
    resolved_channels = resolve_changed_slack_channels(attributes, nil, current_member)
    shop = Shop.new(attributes)
    shop.save!
    assign_resource_managers(shop, manager_ids)
    Service::SlackChannelAssignment.invite_bot_or_notify(resolved_channels, current_member)
    GoogleResourceSyncJob.perform_later("Shop", shop.id.to_s)

    ::Service::AuditLogger.log(
      log_type:       'portal',
      event_type:     'shop_created',
      resource_type:  'Shop',
      resource_id:    shop.id,
      actor:          current_member,
      after_snapshot: shop.attributes,
      message_details: "shop: #{shop.name}"
    )

    render json: shop, serializer: ShopSerializer, adapter: :attributes, sheet_viewer: current_member
  end

  def update
    manager_ids = resource_manager_ids_param
    attributes = shop_params
    resolved_channels = resolve_changed_slack_channels(attributes, @shop, current_member)
    before = @shop.attributes.dup
    @shop.update_attributes!(attributes)
    assign_resource_managers(@shop, manager_ids)
    Service::SlackChannelAssignment.invite_bot_or_notify(resolved_channels, current_member)
    shop_sync_needed = @shop.resource_email.blank? ||
      %w[name reservable color_id].any? { |field| @shop.previous_changes.key?(field) }
    if shop_sync_needed
      GoogleResourceSyncJob.perform_later("Shop", @shop.id.to_s)
    end
    if @shop.previous_changes.key?("color_id")
      @shop.tools.pluck(:id).each do |tool_id|
        GoogleResourceSyncJob.perform_later("Tool", tool_id.to_s)
      end
    end

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'shop_updated',
      resource_type:   'Shop',
      resource_id:     @shop.id,
      actor:           current_member,
      field_changes:   @shop.previous_changes,
      before_snapshot: before,
      after_snapshot:  @shop.attributes,
      message_details: "shop: #{@shop.name}"
    )

    render json: @shop, serializer: ShopSerializer, adapter: :attributes, sheet_viewer: current_member
  end

  # Separate from #update: the "Edit annotation" quick-action on the Shops
  # table only ever needs this one field, mirroring Admin::ToolsController's
  # own dedicated #requestor_annotation action for the same reason (a
  # narrower endpoint for a narrower form, not a permissions difference --
  # both still require can_manage_shop?, same as the full #update).
  def requestor_annotation
    before = @shop.requestor_annotation
    @shop.update_attributes!(params.permit(:requestor_annotation))
    ::Service::AuditLogger.log(
      log_type: 'portal', event_type: 'shop_requestor_annotation_updated',
      resource_type: 'Shop', resource_id: @shop.id, actor: current_member,
      field_changes: { 'requestor_annotation' => [before, @shop.requestor_annotation] }
    )
    render json: @shop, serializer: ShopSerializer, adapter: :attributes, sheet_viewer: current_member
  end

  def destroy
    if Reservation.blocking.where(shop_id: @shop.id, :end_at.gt => Time.current).exists?
      raise ::Error::Conflict.new("Cancel future reservations before deleting this shop")
    end
    prevent_deletion_if_tools_are_referenced
    before = @shop.attributes.dup
    deleted_tool_ids = @shop.tools.pluck(:id).map(&:to_s)
    google_resources = [[@shop.google_resource_id, @shop.id.to_s]] +
      @shop.tools.map { |tool| [tool.google_resource_id, tool.id.to_s] }
    @shop.destroy
    google_resources.each do |resource_id, label_source_id|
      GoogleResourceDeleteJob.perform_later(resource_id, label_source_id)
    end
    Member.shop_resource_manager_candidates.where(:resource_manager_shop_ids.in => [before["_id"].to_s]).each do |member|
      member.pull(resource_manager_shop_ids: before["_id"].to_s)
    end
    CheckoutApprover.where(:shop_ids.in => [before["_id"].to_s]).each do |approver|
      approver.pull(shop_ids: before["_id"].to_s)
      approver.destroy if approver.shop_ids.blank? && approver.tool_ids.blank?
    end
    CheckoutApprover.where(:tool_ids.in => deleted_tool_ids).each do |approver|
      approver.set(tool_ids: Array(approver.tool_ids).map(&:to_s) - deleted_tool_ids)
      approver.destroy if approver.shop_ids.blank? && approver.tool_ids.blank?
    end

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'shop_deleted',
      resource_type:   'Shop',
      resource_id:     before['_id'],
      actor:           current_member,
      before_snapshot: before,
      after_snapshot:  {},
      message_details: "shop: #{before['name']}"
    )

    render json: {}, status: 204
  end

  private

  def resource_manager_ids_param
    return nil unless params.key?(:resource_manager_ids)
    raise ::Error::Forbidden.new unless is_admin? || is_board_member?
    ids = params[:resource_manager_ids]
    unless ids.is_a?(Array) && ids.all? { |id| BSON::ObjectId.legal?(id.to_s) }
      raise ::Error::UnprocessableEntity.new('Choose valid Resource Managers')
    end
    ids = ids.map(&:to_s).uniq
    unless Member.shop_resource_manager_candidates.where(:id.in => ids).count == ids.length
      raise ::Error::UnprocessableEntity.new('Selected members must be Resource Managers, Admins, or Board members')
    end
    ids
  end

  def assign_resource_managers(shop, ids)
    return if ids.nil?
    previous = Member.shop_resource_manager_candidates.where(resource_manager_shop_ids: shop.id.to_s).pluck(:id).map(&:to_s)
    Member.shop_resource_manager_candidates.where(:id.in => ids - previous).each do |member|
      member.add_to_set(resource_manager_shop_ids: shop.id.to_s)
    end
    Member.shop_resource_manager_candidates.where(:id.in => previous - ids).each do |member|
      member.pull(resource_manager_shop_ids: shop.id.to_s)
    end
    return if previous.sort == ids.sort
    ::Service::AuditLogger.log(log_type: 'portal', event_type: 'shop_resource_managers_changed',
      resource_type: 'Shop', resource_id: shop.id, actor: current_member,
      field_changes: { 'resource_manager_ids' => [previous, ids] })
    # Complete the replacement before attempting any external queue work.
    ((ids - previous) + (previous - ids)).each do |member_id|
      begin
        ReservationSlackCanvasMemberAccessJob.perform_later(member_id, [shop.id.to_s])
      rescue StandardError => error
        Rails.logger.error("Canvas access enqueue failed for member #{member_id}, shop #{shop.id}: #{error.class}: #{error.message}")
      end
    end
  end

  def shop_params
    params.permit(
      :name, :requestor_annotation, :wiki_url, :gdrive_id, :slack_channel, :disabled, :reservable,
      :max_concurrent_reservations, :reservation_horizon_days,
      :minimum_advance_notice_hours, :prohibit_same_day_reservations, :reservation_full_day, :max_reservation_duration_hours, :reservation_requires_approval,
      :color_id, :floor_name, :capacity,
      duration_fees: [:invoice_option_id, :minimum_hours, :maximum_hours, :full_day], reservation_prerequisite_tool_ids: []
    )
  end

  def resolve_changed_slack_channels(attributes, shop = nil, actor = nil)
    return {} unless attributes.key?(:slack_channel)

    normalized = Service::SlackChannelCache.normalize_name(attributes[:slack_channel])
    return {} if normalized.blank? || normalized == shop&.slack_channel

    Service::SlackChannelAssignment.resolve!({ slack_channel: normalized }, actor)
  end

  def find_shop
    @shop = Shop.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Shop, { id: params[:id] }) if @shop.nil?
  end

  def authorize_index
    raise ::Error::Forbidden.new unless is_admin? || is_board_member? || is_resource_manager?
  end

  def authorize_create_destroy
    raise ::Error::Forbidden.new unless is_admin? || is_board_member?
  end

  def authorize_update
    raise ::Error::Forbidden.new unless can_manage_shop?(@shop)
  end

  def prevent_deletion_if_tools_are_referenced
    deleted_tool_ids = @shop.tools.pluck(:id)
    if FixTicket.any_of({ shop_id: @shop.id }, { :tool_id.in => deleted_tool_ids }).exists?
      raise ::Error::Conflict.new('Cannot delete a shop referenced by a repair ticket')
    end
    return if deleted_tool_ids.empty?
    prerequisite_ids = deleted_tool_ids.flat_map { |id| [id, id.to_s] }

    surviving_tools = Tool.where(:shop_id.ne => @shop.id)
    checkout_tools = surviving_tools.where(
      :prerequisite_ids.in => prerequisite_ids
    ).to_a
    reservation_tools = surviving_tools.where(
      :reservation_prerequisite_tool_ids.in => prerequisite_ids
    ).to_a
    reservation_shops = Shop.where(:id.ne => @shop.id).where(
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
    references << "checkout prerequisites for tools: #{checkout_tools.map(&:name).join(', ')}" if checkout_tools.any?
    references << "reservation prerequisites for tools: #{reservation_tools.map(&:name).join(', ')}" if reservation_tools.any?
    references << "reservation prerequisites for shops: #{reservation_shops.map(&:name).join(', ')}" if reservation_shops.any?
    references << "volunteer prerequisites for tasks: #{volunteer_tasks.map(&:title).join(', ')}" if volunteer_tasks.any?
    references << "volunteer prerequisites for events: #{volunteer_events.map(&:title).join(', ')}" if volunteer_events.any?

    raise ::Error::Conflict.new(
      "Cannot delete #{@shop.name}; its tools are #{references.join('; ')}"
    )
  end

  def force_deletion?
    ActiveModel::Type::Boolean.new.cast(params[:force])
  end

  def remove_prerequisite_ids(records, field, removed_ids)
    removed_ids = removed_ids.map(&:to_s)
    records.each do |record|
      record.set(field => Array(record.public_send(field)).reject { |id| removed_ids.include?(id.to_s) })
    end
  end
end
