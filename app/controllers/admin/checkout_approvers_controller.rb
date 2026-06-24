class Admin::CheckoutApproversController < AdminOrRmController
  before_action :find_approver, only: [:update, :destroy]

  def index
    approvers = CheckoutApprover.all
    render json: approvers, each_serializer: CheckoutApproverSerializer, adapter: :attributes
  end

  def create
    approver = CheckoutApprover.find_or_initialize_by(member_id: approver_params[:member_id])
    incoming = approver_params[:shop_ids] || []
    approver.shop_ids = (approver.shop_ids + incoming).uniq
    approver.save!

    ::Service::AuditLogger.log(
      log_type:       'portal',
      event_type:     'checkout_approver_created',
      resource_type:  'CheckoutApprover',
      resource_id:    approver.id,
      actor:          current_member,
      after_snapshot: approver.attributes
    )

    render json: approver, serializer: CheckoutApproverSerializer, adapter: :attributes
  end

  def update
    before = @approver.attributes.dup
    @approver.update_attributes!(approver_params)

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'checkout_approver_updated',
      resource_type:   'CheckoutApprover',
      resource_id:     @approver.id,
      actor:           current_member,
      field_changes:   @approver.previous_changes,
      before_snapshot: before,
      after_snapshot:  @approver.attributes
    )

    render json: @approver, serializer: CheckoutApproverSerializer, adapter: :attributes
  end

  def destroy
    before = @approver.attributes.dup
    @approver.destroy

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'checkout_approver_deleted',
      resource_type:   'CheckoutApprover',
      resource_id:     before['_id'],
      actor:           current_member,
      before_snapshot: before,
      after_snapshot:  {}
    )

    render json: {}, status: 204
  end

  private

  def approver_params
    params.permit(:member_id, shop_ids: [])
  end

  def find_approver
    @approver = CheckoutApprover.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(CheckoutApprover, { id: params[:id] }) if @approver.nil?
  end
end
