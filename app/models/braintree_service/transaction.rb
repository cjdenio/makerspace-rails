class BraintreeService::Transaction < Braintree::Transaction
  MAX_TRANSACTION_LIMIT = 500

  include ImportResource
  extend Service::SlackConnector
  include ActiveModel::Serializers::JSON

  attr_writer :invoice

  def self.new(gateway, args)
    super(gateway, args)
  end

  def self.refund(gateway, transaction_id)
    result = gateway.transaction.refund(transaction_id)
    raise ::Error::Braintree::Result.new(result) unless result.success?
    transaction = normalize(gateway, result.transaction)
    invoice = transaction.invoice
    if invoice.nil?
      enque_message("Err: Refunded transaction #{transaction.id} without related invoice. Investigation required")
    else
      invoice.update!({ refunded: true })
      BillingMailer.refund(invoice.member.email, transaction_id, invoice.id.to_s).deliver_later
      enque_message("#{invoice.member.fullname}'s refund of #{invoice.amount} for #{invoice.name} from #{invoice.settled_at} completed.")
    end

    transaction
  end

  def self.get_transactions(gateway, search_query = nil, limit = 50, result_filter = nil)
    begin
      Timeout::timeout(25) do
        limit = [limit, MAX_TRANSACTION_LIMIT].min
        transactions = gateway.transaction.search { |search| search_query && search_query.call(search) }
        # Braintree::ResourceCollection#first does not accept an argument (gem 2.94.0).
        # Use each with a break — fetches IDs in one call then the first page of
        # requested records and stops, preventing H12 timeout and R14 memory errors.
        # Use date filters in the UI to narrow results further.
        results = []
        transactions.each do |transaction|
          transaction = normalize(gateway, transaction)
          next if result_filter && !result_filter.call(transaction)

          results << transaction
          break if results.length >= limit
        end
        results
      end
    rescue Timeout::Error => e
      ::Service::SlackConnector.send_slack_message(
        "⚠️ Braintree transaction search timed out after 25s. Try narrowing the date range. Error: #{e.message}",
        ::Service::SlackConnector.logs_channel
      )
      Service::ErrorReporter.notify(e)
      raise ::Error::UnprocessableEntity.new("Braintree request timed out. Please narrow your date range and try again.")
    end
  end

  def self.get_transaction(gateway, id)
    transaction = gateway.transaction.find(id)
    normalize(gateway, transaction)
  end

  # TODO: This should be split between subscription and transaction models
  def self.submit_invoice_for_settlement(gateway, invoice)
     if invoice.plan_id
      subscription = ::BraintreeService::Subscription.create(gateway, invoice)
      transaction = subscription.transactions.first
      update_hash = { subscription_id: subscription.id }
      # Required due to renewal reminders service
      if Invoice::OPERATION_RESOURCES[invoice.resource_class].method_defined? :subscription
        update_hash[:subscription] = true
      end
      invoice.resource.update!(update_hash)
      BillingMailer.new_subscription(invoice.member.email, subscription.id, invoice.id.to_s).deliver_later
    else
      # Round defensively: Braintree rejects amounts with more than 2 decimal
      # places, and invoices persisted before the Invoice#amount= normalization
      # was added may still carry binary-float drift (e.g. 10.350000000000001).
      sale_amount = invoice.amount.round(2)
      result = gateway.transaction.sale(
        amount: sale_amount,
        order_id: invoice.id.to_s,
        payment_method_token: invoice.payment_method_id,
        line_items: [{
          kind: "debit",
          name: invoice.name,
          quantity: 1,
          total_amount: sale_amount,
          unit_amount: sale_amount
        }],
        options: {
          submit_for_settlement: true
        },
      )
      raise ::Error::Braintree::Result.new(result) unless result.success?
      transaction = result.transaction
    end

    invoice.update!({
      subscription_id: subscription ? subscription.id : nil,
      transaction_id: transaction.id,
    })

    BillingMailer.receipt(invoice.member.email, transaction.id, invoice.id.to_s).deliver_later
    unless subscription.nil?
      enque_message(
        "New subscription from #{invoice.member.fullname} received for #{invoice.name}",
        ::Service::SlackConnector.members_relations_channel,
        ::Service::SlackConnector.request_caller_id("transaction.submit_invoice_for_settlement.subscription.#{invoice.id}")
      )
    end
    enque_message(
      "Payment from #{invoice.member.fullname} of $#{invoice.amount} received for #{invoice.name}",
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("transaction.submit_invoice_for_settlement.payment.#{invoice.id}")
    )
    normalize(gateway, transaction)
  end

  def payment_method
    payment_method_type = self.payment_instrument_type
    payment_method_type == "credit_card" ? self.credit_card_details : self.paypal_details unless payment_method_type.nil?
  end

  def pretty_status
    status.titleize
  end

  def invoice
    return @invoice if defined?(@invoice)

    Invoice.find_by({ transaction_id: id }) || Invoice.find_by({ last_failed_transaction_id: id })
  end

  private
  def self.normalize(gateway, transaction)
    norm_transaction = self.new(gateway, instance_to_hash(transaction))

    # A refund is its own distinct Braintree transaction, separate from the
    # original charge -- Invoice#transaction_id points at the original, so
    # look up by refunded_transaction_id when this is a refund, and cache
    # the result via the invoice= writer so the plain id-based lookup above
    # doesn't run instead and silently find nothing.
    transaction_id = norm_transaction.refunded_transaction_id || norm_transaction.id
    norm_transaction.invoice = Invoice.find_by(transaction_id: transaction_id) ||
      Invoice.find_by(last_failed_transaction_id: transaction_id)
    norm_transaction
  end
end
