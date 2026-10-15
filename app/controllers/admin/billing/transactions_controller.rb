class Admin::Billing::TransactionsController < Admin::BillingController
  def index
    transactions = ::BraintreeService::Transaction.get_transactions(
      @gateway,
      construct_query,
      transaction_limit,
      discount_filter
    )

    return render_with_total_items(transactions, { each_serializer: BraintreeService::TransactionSerializer, adapter: :attributes })
  end

  def show
    transaction = ::BraintreeService::Transaction.get_transaction(@gateway, params[:id])
    render json: transaction, serializer: BraintreeService::TransactionSerializer, adapter: :attributes and return
  end

  def destroy
    ::BraintreeService::Transaction.refund(@gateway, params[:id])

    invoice = Invoice.find_by(transaction_id: params[:id])

    ::Service::AuditLogger.log(
      log_type:        'member',
      event_type:      'transaction_refunded',
      resource_type:   invoice ? 'Invoice' : 'Transaction',
      resource_id:     invoice&.id || current_member.id,
      actor:           current_member,
      subject:         invoice&.member,
      after_snapshot:  { transaction_id: params[:id] },
      message_details: invoice ? "Braintree invoice ID: #{invoice.id}, resource class: #{invoice.resource_class} — $#{invoice.amount} — #{invoice.description}" : "No invoice found for transaction #{params[:id]}",
      slack_channel:   ::Service::SlackConnector.logs_channel
    )

    render json: {}, status: 204 and return
  end

  private
  def construct_query
    Proc.new do |search|
      unless transaction_query_params[:customer_id].nil?
        member = Member.find_by(customer_id: transaction_query_params[:customer_id])
        if member && member.customer_id
          search.customer_id.is(member.customer_id)
        end
      end

      if (transaction_query_params[:end_date] && transaction_query_params[:start_date])
        search.created_at.between(transaction_query_params[:start_date], transaction_query_params[:end_date])
      elsif transaction_query_params[:start_date]
        search.created_at >= transaction_query_params[:start_date]
      elsif transaction_query_params[:end_date]
        search.created_at <= transaction_query_params[:end_date]
      end

      if transaction_query_params[:min_amount] && transaction_query_params[:max_amount]
        search.amount.between(transaction_query_params[:min_amount], transaction_query_params[:max_amount])
      elsif transaction_query_params[:min_amount]
        search.amount >= transaction_query_params[:min_amount]
      elsif transaction_query_params[:max_amount]
        search.amount <= transaction_query_params[:max_amount]
      end

      if transaction_query_params[:refund]
        if transaction_query_params[:type].nil?
          raise ::Error::UnprocessableEntity.new("Type required with refund search")
        else
          search.refund.is(transaction_query_params[:refund])
        end
      end

      search.type.is(transaction_query_params[:type]) unless transaction_query_params[:type].nil?


      unless transaction_query_params[:transaction_status].nil?
        statuses = transaction_query_params[:transaction_status].collect { |status| "Braintree::Transaction::Status::#{status.capitalize}".constantize}

        query_array(statuses, search.status)
      end
    end
  end

  def transaction_query_params
    # The React client sends camelCase minAmount/maxAmount via a raw request
    # helper that bypasses the generated API client's snake_case conversion.
    # Accept both spellings so the filter doesn't silently no-op.
    query_params = params.permit(:start_date, :end_date, :refund, :type, :customer_id, :min_amount, :max_amount, :minAmount, :maxAmount, :limit, :discount_id => [], :transaction_status => [])
    query_params[:min_amount] ||= query_params.delete(:minAmount)
    query_params[:max_amount] ||= query_params.delete(:maxAmount)
    query_params
  end

  def transaction_limit
    Integer(transaction_query_params[:limit] || 50).tap do |limit|
      raise ::Error::UnprocessableEntity.new("Limit must be a positive integer") unless limit.positive?
    end
  rescue ArgumentError, TypeError
    raise ::Error::UnprocessableEntity.new("Limit must be a positive integer")
  end

  def discount_filter
    discount_ids = transaction_query_params[:discount_id]
    return unless discount_ids

    ->(transaction) { transaction.discounts.any? { |discount| discount_ids.include?(discount.id) } }
  end
end
