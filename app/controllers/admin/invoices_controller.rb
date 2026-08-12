class Admin::InvoicesController < AdminOrRmController
  include FastQuery::MongoidQuery
  include BraintreeGateway
  before_action :find_invoice, only: [:update, :destroy, :force_cancel]

  # Allow Resource Managers to manage shop fee invoices (resource_class: "fee") only.
  # Full admin/board access remains for all invoice types and actions.
  before_action :authorize_invoice_action, only: [:index, :create, :update, :destroy]

  def index
    # Special case: orphaned invoices (subscription cancelled but invoices not cleaned up)
    if invoice_query_params[:orphaned] == 'true'
      orphaned = Invoice.orphaned
      # Invoice.orphaned uses Array#select internally, so it returns a plain
      # Array, not a chainable Mongoid::Criteria — fee_invoices_only's
      # .where call would raise NoMethodError on an Array. Filter with
      # Array#select here instead for this one path.
      orphaned = orphaned.select { |invoice| invoice.resource_class == "fee" } unless invoice_admin?
      return render json: orphaned, each_serializer: InvoiceSerializer, adapter: :attributes
    end

    @queries = invoice_query_params.keys.map do |k|
      key = k.to_sym

      if key === :settled
        query = query_to_bool(invoice_query_params[:settled],
          {"$or" => [
            { :settled_at.ne => nil },
            { :transaction_id.ne => nil }
          ]},
          {"$and" => [
            { settled_at: nil },
            { transaction_id: nil }
          ]},
        )
      elsif key === :past_due
        query = query_to_bool(invoice_query_params[:past_due],
          {"$or" => [
            { settled_at: nil },
            { transaction_id: nil }
          ], :due_date.lt => Time.now },
          {"$or" => [
            {"$and" => [
              { :settled_at.ne => nil },
              { :transaction_id.ne => nil }
            ]},
            :due_date.gte => Time.now] }
        )
      elsif bool_params.include?(key)
        query = query_bool_by_name(invoice_query_params[key], key)
      elsif array_params.include?(key)
        query = query_array_by_name(invoice_query_params[key], key)
      elsif exist_params.include?(key)
        query = query_existance_by_name(invoice_query_params[key], key)
      end

      build_query(query)
    end

    invoices = @queries.length > 0 ? Invoice.where(@queries.reduce(&:merge)) : Invoice.all
    invoices = fee_invoices_only(invoices) unless invoice_admin?
    invoices = query_resource(invoices) # Query with the usual sorting, paging and searching

    return render_with_total_items(invoices, { each_serializer: InvoiceSerializer, adapter: :attributes })
  end

  # Create an invoice from an invoice option (or raw params for admins with customBilling)
  def create
    if params['id']
      member = Member.find(invoice_option_params[:member_id])
      raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: invoice_option_params[:member_id] }) if member.nil?
      invoice_option = InvoiceOption.find(invoice_option_params[:id])
      raise ::Mongoid::Errors::DocumentNotFound.new(InvoiceOption, { id: invoice_option_params[:id] }) if invoice_option.nil?
      if (invoice_option_params[:discount_id])
        discounts = ::BraintreeService::Discount.get_discounts(@gateway)
        invoice_discount = discounts.find { |d| d.id == invoice_option_params[:discount_id]}
      end
      invoice = invoice_option.build_invoice(member.id, Time.now, invoice_option_params[:resource_id], invoice_discount)
    else
      invoice = Invoice.new(create_invoice_params)
      invoice.save!
    end

    ::Service::AuditLogger.log(
      log_type: 'member', event_type: 'invoice_created', resource_type: 'Invoice',
      resource_id: invoice.id, actor: current_member, subject: invoice.member,
      field_changes: invoice.previous_changes, before_snapshot: {},
      after_snapshot: invoice.attributes, slack_channel: ::Service::SlackConnector.logs_channel
    )

    render json: invoice, adapter: :attributes and return
  end

  def update
    before = @invoice.attributes.dup
    if !!update_invoice_params[:settled] && !@invoice.settled
      @invoice.submit_for_settlement(nil, nil, nil)
    else
      @invoice.update_attributes!(update_invoice_params)
    end

    ::Service::AuditLogger.log(
      log_type: 'member', event_type: 'invoice_updated', resource_type: 'Invoice',
      resource_id: @invoice.id, actor: current_member, subject: @invoice.member,
      field_changes: @invoice.previous_changes, before_snapshot: before,
      after_snapshot: @invoice.reload.attributes, slack_channel: ::Service::SlackConnector.logs_channel
    )

    render json: @invoice, adapter: :attributes and return
  end

  def destroy
    before = @invoice.attributes.dup
    member = @invoice.member
    @invoice.destroy

    ::Service::AuditLogger.log(
      log_type: 'member', event_type: 'invoice_deleted', resource_type: 'Invoice',
      resource_id: before['_id'], actor: current_member, subject: member,
      field_changes: {}, before_snapshot: before,
      after_snapshot: {}, slack_channel: ::Service::SlackConnector.logs_channel
    )

    render json: {}, status: 204 and return
  end

  # POST /api/admin/invoices/:id/force_cancel
  # Cleans up orphaned invoices left when a Braintree subscription cancellation
  # partially failed. Destroys all unsettled invoices tied to the same
  # subscription_id and clears the member's subscription fields.
  # Admin and board members only.
  def force_cancel
    unless is_admin? || is_board_member?
      render json: { error: 'Only admins and board members can force cancel invoices' }, status: :forbidden and return
    end

    unless @invoice.subscription_id.present?
      render json: { error: 'Invoice has no subscription_id — nothing to clean up' }, status: :unprocessable_content and return
    end

    before = @invoice.attributes.dup
    member = @invoice.member

    Invoice.force_cancel(@invoice.id)

    ::Service::AuditLogger.log(
      log_type: 'member', event_type: 'invoice_force_cancelled', resource_type: 'Invoice',
      resource_id: before['_id'], actor: current_member, subject: member,
      field_changes: {}, before_snapshot: before,
      after_snapshot: {}, slack_channel: ::Service::SlackConnector.logs_channel
    )

    render json: {}, status: 204 and return
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
    render json: { error: e.message }, status: :unprocessable_content and return
  end

  private

  # Admins/board can manage any invoice type and action.
  # Resource Managers can only create/view/update/delete fee invoices
  # (shop charges) — and cannot change an existing invoice's resource_class
  # away from "fee" to escape the restriction.
  def authorize_invoice_action
    return if invoice_admin?
    case action_name
    when "index"
      return
    when "create"
      resource_class = requested_invoice_resource_class
      requested_class = params[:resource_class]
      error_message = "Resource managers may only create shop fee invoices"
    else
      resource_class = @invoice&.resource_class
      requested_class = params[:resource_class]
      error_message = "Resource managers may only manage shop fee invoices"
    end
    unless resource_class == "fee" && (requested_class.blank? || requested_class == "fee")
      render json: { error: error_message }, status: 403
    end
  end

  def invoice_admin?
    is_admin? || is_board_member?
  end

  def fee_invoices_only(invoices)
    invoices.where(resource_class: "fee")
  end

  def requested_invoice_resource_class
    params[:resource_class]
  end

  def update_invoice_params
    params.permit(:description,
                  :name,
                  :items,
                  :settled,
                  :amount,
                  :quantity,
                  :payment_type,
                  :resource_id,
                  :resource_class,
                  :due_date,
                  :member_id)
  end

  def create_invoice_params
    params.require([:amount, :quantity, :resource_id, :resource_class, :member_id])
    update_invoice_params
  end

  def invoice_option_params
    params.require([:id, :member_id, :resource_id])
    params.permit(:id, :discount_id, :member_id, :resource_id)
  end

  def find_invoice
    @invoice = Invoice.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Invoice, { id: params[:id] }) if @invoice.nil?
  end

  def invoice_query_params
    params.permit(:settled, :past_due, :refunded, :refund_requested, :orphaned, :plan_id => [], :resource_class => [], :resource_id => [], :member_id => [])
  end

  def bool_params
    [:refunded]
  end

  def array_params
    [:resource_class, :resource_id, :member_id, :plan_id]
  end

  def exist_params
    [:refund_requested]
  end

  def build_query(query)
    query || {}
  end
end
