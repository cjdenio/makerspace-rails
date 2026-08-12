class Admin::ShopsController < ApplicationController
  before_action :authenticate_member!
  before_action :authorize_index, only: [:index]
  before_action :authorize_create_destroy, only: [:create, :destroy]
  before_action :find_shop, only: [:update, :destroy]
  before_action :authorize_update, only: [:update]

  def index
    shops = if is_admin? || is_board_member?
      Shop.all
    else
      Shop.where(:id.in => managed_shop_ids)
    end
    shops = shops.order_by(name: :asc)
    render json: shops, each_serializer: ShopSerializer, adapter: :attributes
  end

  def create
    shop = Shop.new(shop_params)
    shop.save!
    GoogleResourceSyncJob.perform_later("Shop", shop.id.to_s)

    ::Service::AuditLogger.log(
      log_type:       'portal',
      event_type:     'shop_created',
      resource_type:  'Shop',
      resource_id:    shop.id,
      actor:          current_member,
      after_snapshot: shop.attributes
    )

    render json: shop, serializer: ShopSerializer, adapter: :attributes
  end

  def update
    before = @shop.attributes.dup
    @shop.update_attributes!(shop_params)
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
      after_snapshot:  @shop.attributes
    )

    render json: @shop, serializer: ShopSerializer, adapter: :attributes
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
    Member.where(role: "resource_manager", :resource_manager_shop_ids.in => [before["_id"].to_s]).each do |member|
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
      after_snapshot:  {}
    )

    render json: {}, status: 204
  end

  private

  def shop_params
    params.permit(
      :name, :wiki_url, :gdrive_id, :slack_channel, :disabled, :reservable,
      :max_concurrent_reservations, :reservation_horizon_days,
      :max_reservation_duration_hours, :reservation_requires_approval,
      :color_id,
      reservation_prerequisite_tool_ids: []
    )
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
