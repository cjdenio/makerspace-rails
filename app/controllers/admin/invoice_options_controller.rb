class Admin::InvoiceOptionsController < AdminOrRmController
  include FastQuery::MongoidQuery
  before_action :find_invoice_option, only: [:update, :destroy]
  before_action :authorize_fee_action, only: [:create, :update, :destroy]

  def create
    invoice_option = InvoiceOption.new(create_params)
    invoice_option.save!

    ::Service::AuditLogger.log(
      log_type:       'portal',
      event_type:     'invoice_option_created',
      resource_type:  'InvoiceOption',
      resource_id:    invoice_option.id,
      actor:          current_member,
      after_snapshot: invoice_option.attributes
    )

    render json: invoice_option, each_serializer: InvoiceOptionSerializer, adapter: :attributes and return
  end

  def update
    before = @invoice_option.attributes.dup
    @invoice_option.update_attributes!(invoice_params)

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'invoice_option_updated',
      resource_type:   'InvoiceOption',
      resource_id:     @invoice_option.id,
      actor:           current_member,
      field_changes:   @invoice_option.previous_changes,
      before_snapshot: before,
      after_snapshot:  @invoice_option.attributes
    )

    render json: @invoice_option, adapter: :attributes and return
  end

  def destroy
    if in_use_check_fails_safe(@invoice_option)
      message = "Cannot delete \"#{@invoice_option.name}\" -- a member or rental is still on this plan. Disable it instead."

      ::Service::AuditLogger.log(
        log_type:        'portal',
        event_type:      'invoice_option_delete_blocked',
        resource_type:   'InvoiceOption',
        resource_id:     @invoice_option.id,
        actor:           current_member,
        before_snapshot: @invoice_option.attributes,
        message_details: message
      )

      raise ::Error::Conflict.new(message)
    end

    before = @invoice_option.attributes.dup
    @invoice_option.destroy

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'invoice_option_deleted',
      resource_type:   'InvoiceOption',
      resource_id:     before['_id'],
      actor:           current_member,
      before_snapshot: before,
      after_snapshot:  {}
    )

    render json: {}, status: 204 and return
  end

  private

  # Blocks deletion whenever the option is still "in use," even if deleting
  # it wouldn't technically break anything (Invoice is fully denormalized at
  # creation time -- see InvoiceOption#build_invoice -- so historical and
  # even future renewal invoices are unaffected either way). This is a
  # deliberate safety guard, not a technical necessity: a plan someone is
  # actively on shouldn't disappear out from under them, and RentalType
  # still holds a live, unguarded reference to invoice_option_id that would
  # silently orphan if the option it points to were removed.
  def in_use_by_subscribers?(option)
    return true if RentalType.where(invoice_option_id: option.id.to_s).exists?
    return true if option.plan_id.present? && Invoice.where(plan_id: option.plan_id, settled_at: nil).exists?

    false
  end

  # Wraps in_use_by_subscribers? so a failure in the check itself (a DB
  # hiccup, etc.) can never silently let a delete through. On error we log,
  # notify Honeybadger, and post to Slack, then fail safe by treating the
  # option as in use -- blocking the delete rather than risking removing
  # something still relied on.
  def in_use_check_fails_safe(option)
    in_use_by_subscribers?(option)
  rescue => e
    context = {
      invoice_option_id: option.id.to_s,
      actor_id:          current_member&.id&.to_s,
      phase:              'invoice_option_delete_subscriber_check'
    }
    ::Service::ErrorReporter.notify(e, context: context)
    ::Service::SlackConnector.send_slack_message(
      "Failed to verify whether \"#{option.name}\" (#{option.id}) has active subscribers before deletion -- " \
      "blocking the delete to be safe. Error: #{e.class}: #{e.message}",
      ::Service::SlackConnector.logs_channel
    )
    true
  end

  # Admins can manage all invoice option types.
  # Resource Managers can only manage fee-type invoice options (the shop fee catalog).
  def authorize_fee_action
    return if is_admin? || is_board_member?
    # For create: check incoming resource_class param
    # For update/destroy: check the existing record's resource_class
    target_class = @invoice_option ? @invoice_option.resource_class : params[:resource_class]
    requested_class = params[:resource_class]
    unless target_class == "fee" && (requested_class.blank? || requested_class == "fee")
      render json: { error: "Resource managers may only manage shop fee catalog items" }, status: 403
    end
  end

  def create_params
    params.require([:name, :resource_class, :amount, :quantity])
    invoice_params
  end

  def invoice_params
    params.permit(:description, :name, :resource_class, :amount, :quantity, :disabled, :plan_id, :discount_id, :promotion_end_date)
  end

  def find_invoice_option
    @invoice_option = InvoiceOption.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(InvoiceOption, { id: params[:id] }) if @invoice_option.nil?
  end
end
