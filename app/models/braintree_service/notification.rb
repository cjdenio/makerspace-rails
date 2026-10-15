class BraintreeService::Notification
  include Mongoid::Document
  extend Service::SlackConnector

  store_in collection: 'braintree__notifications'

  attr_accessor :notification

  field :kind, type: String
  field :timestamp, type: Date
  field :payload, type: String

  def self.process(notification)
    notification_record = self.create!({
      kind: notification.kind,
      timestamp: notification.timestamp,
      payload: as_json(notification)
    })

    if subscription_notifications.include?(notification.kind)
      process_subscription(notification, notification_record)
    elsif dispute_notifications.include?(notification.kind)
      process_dispute(notification)
    elsif transaction_notifications.include?(notification.kind)
      process_transaction(notification, 0, notification_record)
    end
  end

  protected
  def self.as_json(notification)
    JSON.generate(get_details_for_notification(notification))
  end

  def self.get_details_for_notification(notification)
    if subscription_notifications.include?(notification.kind)
      if notification.subscription.nil?
        enque_message("Received malformed subscription notification. Do not know how to process.")
        return
      end

      resource_class, resource_id = ::BraintreeService::Subscription.read_id(notification.subscription.id)
      transaction = notification.subscription.transactions.first
      member = member_for_subscription(resource_class, resource_id, transaction)

      {
        subscription_id: notification.subscription.id,
        transaction_id: transaction&.id,
        resource_class: resource_class,
        resource_id: resource_id,
        incomingPayment: payment_log_details(
          transaction,
          nil,
          member&.id
        )[:incomingPayment]
      }
    elsif dispute_notifications.include?(notification.kind)
      if notification.dispute.nil?
        enque_message("Received malformed dispute notification. Do not know how to process.")
        return
      end

      {
        dispute_status: notification.dispute.status,
        reason: notification.dispute.reason,
        transaction_id: notification.dispute.transaction ? notification.dispute.transaction.id : nil,

      }
    elsif transaction_notifications.include?(notification.kind)
      if notification.transaction.nil?
        enque_message("Received malformed transaction notification. Do not know how to process.")
        return
      end

      member = member_for_transaction(notification.transaction)
      {
        transaction_id: notification.transaction.id,
        status: notification.transaction.status,
        incomingPayment: payment_log_details(
          notification.transaction,
          nil,
          member&.id
        )[:incomingPayment]
      }
    else
      enque_message("Received unknown notification #{notification.kind}")
      nil
    end
  end

  def self.process_subscription(notification, notification_record = nil)
    subscription_id = notification.subscription.id
    resource_class, resource_id = ::BraintreeService::Subscription.read_id(subscription_id)
    last_transaction = notification.subscription.transactions.first
    related_resource = Invoice.resource(resource_class, resource_id)
    transaction_member = member_for_transaction(last_transaction)

    payment_notification = [
      ::Braintree::WebhookNotification::Kind::SubscriptionChargedSuccessfully,
      ::Braintree::WebhookNotification::Kind::SubscriptionChargedUnsuccessfully
    ].include?(notification.kind)
    failed_payment_notification = notification.kind === ::Braintree::WebhookNotification::Kind::SubscriptionChargedUnsuccessfully
    invoice = if payment_notification && last_transaction
      matching_invoice = find_invoice_matching_transaction_amount(last_transaction) do |amount|
        Invoice.oldest_active_subscription_invoice_matching_amount(
          subscription_id: last_transaction.try(:subscription_id).presence || subscription_id,
          plan_id: last_transaction.try(:plan_id).presence || notification.subscription.try(:plan_id),
          resource_id: resource_id,
          member_id: transaction_member&.id,
          resource_class: resource_class,
          amount: amount
        )
      end
      matching_invoice || (Invoice.active_invoice_for_resource(resource_id) if failed_payment_notification)
    else
      Invoice.active_invoice_for_resource(resource_id)
    end
    if invoice.nil?
      if payment_notification && !failed_payment_notification && last_transaction
        log_unmatched_payment(
          last_transaction,
          notification,
          related_resource,
          resource_class,
          resource_id,
          notification_record
        )
        return
      end

      identifier = "#{resource_class} ID #{resource_id}"

      unless related_resource.nil?
        if related_resource.class.name == "Member"
          identifier = "Membership for #{get_member_profile(related_resource)}"
        else
          identifier = "Rental for #{related_resource.number} belonging to #{related_resource.member.fullname}"
        end
      end

      if !related_resource.nil? &&
         (
          prior_sub_notification_for_resource(related_resource).nil? || prior_sub_notification_for_resource(related_resource).empty?
         )

        enque_message("Received subscription notification for #{identifier}. No active invoice found; skipping processing. If member just signed up, no further action required.", ::Service::SlackConnector.treasurer_channel)
      elsif (notification.kind === ::Braintree::WebhookNotification::Kind::SubscriptionCanceled)
        enque_message("Received cancelation notification for canceled subscription for #{identifier}", ::Service::SlackConnector.treasurer_channel)
      elsif (notification.kind === ::Braintree::WebhookNotification::Kind::SubscriptionChargedUnsuccessfully)
        enque_message("Received failed payment notification for canceled subscription for #{identifier}")
      else
        enque_message("Unable to process subscription notification: #{notification.kind.to_s}. No active invoice found for #{identifier}.")
      end

      return
    end

    if (last_transaction && notification.kind === ::Braintree::WebhookNotification::Kind::SubscriptionChargedSuccessfully)
      process_subscription_charge_success(invoice, last_transaction)
    elsif (last_transaction && notification.kind === ::Braintree::WebhookNotification::Kind::SubscriptionChargedUnsuccessfully)
      process_subscription_charge_failure(invoice, last_transaction)
    elsif (notification.kind === ::Braintree::WebhookNotification::Kind::SubscriptionCanceled)
      process_subscription_cancellation(invoice)
    elsif (notification.kind === ::Braintree::WebhookNotification::Kind::SubscriptionWentPastDue)
      process_subscription_past_due(invoice)
    else
      enque_message("Received the following notification from Braintree regarding #{invoice.member.fullname}'s subscription':
Type: #{notification.kind}.
Payload: #{notification.as_json}.
Most Recent Transaction (if any): #{last_transaction && last_transaction.as_json}.
No automated actions have been taken at this time.")
    end
  end

  def self.process_subscription_charge_success(invoice, last_transaction)
    if InvoiceHelper.get_lifecycle(invoice.id) == InvoiceHelper::LIFECYCLES[:InProgress]
      enque_message("Duplicate SubscriptionChargedSuccessfully notification for in-progress invoice #{invoice.id}. Skipping processing", ::Service::SlackConnector.treasurer_channel)
      return
    elsif InvoiceHelper.get_lifecycle(invoice.id) == InvoiceHelper::LIFECYCLES[:Success]
      enque_message("Duplicate SubscriptionChargedSuccessfully notification for successful invoice #{invoice.id}. Skipping processing", ::Service::SlackConnector.treasurer_channel)
      return
    end
    
    dupe_invoice = Invoice.find_by(transaction_id: last_transaction.id, :id.ne => invoice.id)
    if dupe_invoice.nil?
      claimed_invoice = Invoice.claim_for_transaction(invoice.id, last_transaction.id)
      unless claimed_invoice
        enque_message("Duplicate SubscriptionChargedSuccessfully notification for claimed invoice #{invoice.id}. Skipping processing", ::Service::SlackConnector.treasurer_channel)
        return
      end

      InvoiceHelper.pay_workflow(
        claimed_invoice.id,
        Proc.new { process_success(claimed_invoice, last_transaction) }
      )
    else
      enque_message("Received duplicate notification regarding #{invoice.name} for #{invoice.member.fullname}. TID: #{last_transaction.id}", ::Service::SlackConnector.treasurer_channel)
    end
  ensure
    claimed_invoice&.update!(locked: false, locked_at: nil)
  end

  def self.process_subscription_charge_failure(invoice, last_transaction)
    # Record which transaction this failed attempt was, so it can still be
    # linked back to this invoice (member, plan, description) when viewed
    # later -- a plain update, not Invoice.claim_for_transaction, since a
    # failed attempt never settles anything and must not touch transaction_id
    # itself (that would block a later successful attempt from claiming it).
    invoice.update(last_failed_transaction_id: last_transaction.id)

    slack_member = SlackUser.find_by(member_id: invoice.member.id)
    member_notified = slack_member ? "The member has been notified via Slack and email as well." : "Unable to notify member via Slack. Reach out to member to resolve."
    unless slack_member.nil?
      enque_message(
        "Your recurring payment for #{invoice.name} was unsuccessful. Error status: #{last_transaction.status}. Please <#{Rails.configuration.x.app_base_url}/#{invoice.member.id}/settings|review your payment settings> or contact an administrator for assistance.",
        slack_member.slack_id,
        ::Service::SlackConnector.request_caller_id("notification.process_subscription_charge_failure.member.#{invoice.id}")
      )
    end
    enque_message(
      "Recurring payment from #{get_member_profile(invoice.member)} failed with status: #{last_transaction.status}. #{member_notified}",
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("notification.process_subscription_charge_failure.management.#{invoice.id}")
    )
    BillingMailer.failed_payment(invoice.member.email, invoice.id.to_s, last_transaction.status).deliver_later
  end

  def self.process_subscription_past_due(invoice)
    slack_member = SlackUser.find_by(member_id: invoice.member.id)
    settings_url = "#{Rails.configuration.x.app_base_url}/#{invoice.member.id}/settings"
    member_notified = slack_member ? "The member has been notified via Slack and email." : "Unable to notify member via Slack. Reach out to member to resolve."

    unless slack_member.nil?
      enque_message(
        "Your recurring payment for #{invoice.name} is past due. Please <#{settings_url}|review your payment settings> or contact an administrator for assistance.",
        slack_member.slack_id,
        ::Service::SlackConnector.request_caller_id("notification.process_subscription_past_due.member.#{invoice.id}")
      )
    end

    enque_message(
      "Subscription for #{get_member_profile(invoice.member)} went past due for #{invoice.name}. #{member_notified}",
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("notification.process_subscription_past_due.management.#{invoice.id}")
    )

    BillingMailer.failed_payment(invoice.member.email, invoice.id.to_s, "past_due").deliver_later
  end

  def self.process_subscription_cancellation(invoice)
    if InvoiceHelper.get_lifecycle(invoice.id) == InvoiceHelper::LIFECYCLES[:Cancelling]
      enque_message("Duplicate SubscriptionCanceled notification for in-progress cancellation invoice #{invoice.id}. Skipping processing", ::Service::SlackConnector.treasurer_channel)
      return
    elsif InvoiceHelper.get_lifecycle(invoice.id) == InvoiceHelper::LIFECYCLES[:Cancelled]
      enque_message("Duplicate SubscriptionCanceled notification for cancelled invoice #{invoice.id}. Skipping processing", ::Service::SlackConnector.treasurer_channel)
      return
    end
    Invoice.process_cancellation(invoice.id)
  end

  def self.process_dispute(notification)
    disputed_transaction = notification.dispute.transaction

    associated_invoice = Invoice.find_by(transaction_id: disputed_transaction.id)
    if associated_invoice.nil?
      enque_message("Dispute received for unknown transaction ID #{disputed_transaction.id}. Cannot find related invoice.")
      return
    end

    enque_message("Received dispute from #{get_member_profile(associated_invoice.member)} for #{associated_invoice.name} which was paid #{associated_invoice.settled_at}.
    Braintree transaction ID #{disputed_transaction.id} |  <#{Rails.configuration.x.app_base_url}/billing/transactions/#{associated_invoice.transaction_id}|Disputed Invoice>")
    if notification.kind === ::Braintree::WebhookNotification::Kind::DisputeOpened
      associated_invoice.set_dispute_requested
      BillingMailer.dispute_requested(associated_invoice.member.email, associated_invoice.id.to_s).deliver_later
    else
      associated_invoice.set_disputed
      if notification.kind === ::Braintree::WebhookNotification::Kind::DisputeWon
        BillingMailer.dispute_won(associated_invoice.member.email, associated_invoice.id.to_s).deliver_later
      elsif notification.kind === ::Braintree::WebhookNotification::Kind::DisputeLost
        BillingMailer.dispute_lost(associated_invoice.member.email, associated_invoice.id.to_s).deliver_later
      end
    end
  end

  def self.process_transaction(notification, claim_attempt = 0, notification_record = nil)
    last_transaction = notification.transaction
    processed_invoice = Invoice.find_by(transaction_id: last_transaction.id)
    requires_claim = false
    claim_acquired = false

    if notification.kind === Braintree::WebhookNotification::Kind::TransactionSettled &&
       processed_invoice&.settlement_processed_at
      enque_message(
        "Duplicate TransactionSettled notification for processed transaction #{last_transaction.id}. Skipping processing",
        ::Service::SlackConnector.treasurer_channel
      )
      return
    end

    if notification.kind === Braintree::WebhookNotification::Kind::TransactionSettled &&
       processed_invoice&.locked
      reclaimed_invoice = Invoice.claim_for_transaction(processed_invoice.id, last_transaction.id)
      if reclaimed_invoice
        processed_invoice = reclaimed_invoice
        requires_claim = true
        claim_acquired = true
      else
        enque_message(
          "Duplicate TransactionSettled notification for claimed transaction #{last_transaction.id}. Skipping processing",
          ::Service::SlackConnector.treasurer_channel
        )
        return
      end
    end

    if processed_invoice.nil? && notification.kind === Braintree::WebhookNotification::Kind::TransactionSettled
      member = member_for_transaction(last_transaction)
      subscription_id = last_transaction.try(:subscription_id)

      if subscription_id.present?
        resource_class, resource_id = ::BraintreeService::Subscription.read_id(subscription_id)
        processed_invoice = find_invoice_matching_transaction_amount(last_transaction) do |amount|
          Invoice.oldest_active_subscription_invoice_matching_amount(
            subscription_id: subscription_id,
            plan_id: last_transaction.try(:plan_id),
            resource_id: resource_id,
            member_id: member&.id,
            resource_class: resource_class,
            amount: amount
          )
        end
      else
        order_id = last_transaction.try(:order_id).to_s
        if order_id.match?(/\A[0-9a-f]{24}\z/i)
          order_id_invoice = Invoice.find_by(id: order_id, settled_at: nil, transaction_id: nil)
          if order_id_invoice
            if order_id_invoice.member_id == member&.id
              processed_invoice = order_id_invoice
            else
              log_order_id_ownership_mismatch(last_transaction, notification, order_id_invoice, member, notification_record)
            end
          end
        end
        if member
          processed_invoice ||= find_invoice_matching_transaction_amount(last_transaction) do |amount|
            Invoice.oldest_active_invoice_for_member_matching_amount(member.id, amount)
          end
        end
      end

      requires_claim = processed_invoice.present?

      if processed_invoice.nil?
        log_unmatched_payment(
          last_transaction,
          notification,
          member,
          "member",
          member&.id,
          notification_record
        )
        return
      end
    end

    if requires_claim && !claim_acquired
      claimed_invoice = Invoice.claim_for_transaction(processed_invoice.id, last_transaction.id)
      unless claimed_invoice
        if Invoice.where(transaction_id: last_transaction.id).exists?
          enque_message(
            "Duplicate TransactionSettled notification for claimed transaction #{last_transaction.id}. Skipping processing",
            ::Service::SlackConnector.treasurer_channel
          )
          return
        end

        if claim_attempt < 2
          return process_transaction(notification, claim_attempt + 1, notification_record)
        end

        log_unmatched_payment(
          last_transaction,
          notification,
          member,
          "member",
          member&.id,
          notification_record
        )
        return
      end
      processed_invoice = claimed_invoice
      claim_acquired = true
    end

    if processed_invoice.nil?
      enque_message("Unable to process transaction notification. No invoice found matching transaction ID #{last_transaction.id}.")
      return
    end

    if notification.kind === Braintree::WebhookNotification::Kind::TransactionSettlementDeclined
      claimed_invoice = Invoice.claim_for_settlement_decline(processed_invoice.id, last_transaction.id)
      unless claimed_invoice
        raise ::Error::Conflict.new(
          "Settlement decline for transaction #{last_transaction.id} is waiting for active invoice processing"
        )
      end
      processed_invoice = claimed_invoice
      decline_claim_acquired = true
    end

    slack_member = SlackUser.find_by(member_id: processed_invoice.member.id)

    if notification.kind === Braintree::WebhookNotification::Kind::TransactionSettled
      if (processed_invoice.settled)
        enque_message("Pending transaction from #{get_member_profile(processed_invoice.member)} successful. No further action needed", ::Service::SlackConnector.treasurer_channel)
      else
        begin
          self.process_success(processed_invoice, last_transaction)
        ensure
          processed_invoice.update!(locked: false, locked_at: nil) if requires_claim
        end
      end
    elsif notification.kind === Braintree::WebhookNotification::Kind::TransactionSettlementDeclined
      begin
        # reverse_settlement re-fetches the resource internally (Invoice#resource
        # is not memoized), so we can't rely on previous_changes from a shared
        # instance here — take manual before/after snapshots instead.
        resource_before = processed_invoice.resource&.attributes&.dup
        processed_invoice.reverse_settlement
        resource_after = processed_invoice.resource&.attributes
        ::Service::AuditLogger.log(
          log_type:        "member",
          event_type:      "invoice_settlement_reversed",
          resource_type:   (processed_invoice.resource&.class&.name || processed_invoice.resource_class),
          resource_id:     processed_invoice.resource_id,
          subject:         processed_invoice.member,
          before_snapshot: resource_before,
          after_snapshot:  resource_after,
          message_details: "Braintree invoice ID: #{processed_invoice.id}, resource class: #{processed_invoice.resource_class} — Settlement declined with status: #{last_transaction.status}"
        )
        member_notified = slack_member ? "The member has been notified via Slack and email as well." : "Unable to notify member via Slack. Reach out to member to resolve."
        unless slack_member.nil?
          enque_message(
            "Your payment for #{processed_invoice.name} was unsuccessful. Error status: #{last_transaction.status}. Please <#{Rails.configuration.x.app_base_url}/#{processed_invoice.member.id}/settings|review your payment settings> or contact an administrator for assistance.",
            slack_member.slack_id,
            ::Service::SlackConnector.request_caller_id("notification.process_transaction.member.#{processed_invoice.id}")
          )
        end
        enque_message(
          "Recent transaction from #{get_member_profile(processed_invoice.member)} for #{processed_invoice.name} failed with status: #{last_transaction.status}. #{member_notified}",
          ::Service::SlackConnector.members_relations_channel,
          ::Service::SlackConnector.request_caller_id("notification.process_transaction.management.#{processed_invoice.id}")
        )
        BillingMailer.failed_payment(processed_invoice.member.email, processed_invoice.id.to_s, last_transaction.status).deliver_later
      ensure
        processed_invoice.update!(locked: false, locked_at: nil) if decline_claim_acquired
      end
    end
  end

  private
  def self.subscription_notifications
    [
      ::Braintree::WebhookNotification::Kind::SubscriptionCanceled,
      ::Braintree::WebhookNotification::Kind::SubscriptionChargedSuccessfully,
      ::Braintree::WebhookNotification::Kind::SubscriptionChargedUnsuccessfully,
      ::Braintree::WebhookNotification::Kind::SubscriptionExpired,
      ::Braintree::WebhookNotification::Kind::SubscriptionTrialEnded,
      ::Braintree::WebhookNotification::Kind::SubscriptionWentActive,
      ::Braintree::WebhookNotification::Kind::SubscriptionWentPastDue,
    ]
  end

  def self.dispute_notifications
    [
      ::Braintree::WebhookNotification::Kind::DisputeLost,
      ::Braintree::WebhookNotification::Kind::DisputeOpened,
      ::Braintree::WebhookNotification::Kind::DisputeWon,
    ]
  end

  def self.transaction_notifications
    [
      Braintree::WebhookNotification::Kind::TransactionSettlementDeclined,
      Braintree::WebhookNotification::Kind::TransactionSettled
    ]
  end

  def self.process_success(invoice, transaction)
    enque_message("#{invoice.subscription_id ? "Recurring" : "One-time"} payment from #{invoice.member.fullname} successful. Processing invoice...")
    begin
      invoice.submit_for_settlement(nil, nil, transaction.id)
    rescue ::Error::NotFound
      enque_message("Unable to process recurring payment. Unknown resource for invoice ID #{invoice.id}.")
      return
    rescue ::Error::UnprocessableEntity => err
      enque_message("Unable to process recurring payment for invoice ID #{invoice.id}. Error: #{err.message}")
      return
    end

    invoice.reload
    invoice.update!(settlement_processed_at: Time.current)
    log_invoice_settled(invoice, transaction) if invoice.settled
    BillingMailer.receipt(invoice.member.email, transaction.id.as_json, invoice.id.as_json).deliver_later
  end

  def self.log_invoice_settled(invoice, transaction)
    snapshot = payment_log_details(transaction, invoice)
    message_details = "Braintree invoice ID: #{invoice.id}, resource class: #{invoice.resource_class}"

    if discount_confirmed_match?(invoice, transaction)
      total_discount = transaction_discount_total(transaction)
      discount_text = transaction_discounts(transaction).map do |discount|
        quantity = discount.try(:quantity).presence || 1
        credited = BigDecimal(discount.try(:amount).to_s) * quantity.to_i
        "#{discount.try(:name)}: $#{format('%.2f', credited)}"
      end
      snapshot[:discountMatch] = {
        memberId: invoice.member_id.to_s,
        planId: transaction.try(:plan_id).presence || invoice.plan_id,
        invoiceId: invoice.id.to_s,
        totalDiscountApplied: total_discount.to_f,
        discounts: discount_text
      }
      message_details += " — Discount-confirmed match; total discount $#{format('%.2f', total_discount)} " \
        "(#{discount_text.join(', ')})"
    end

    ::Service::AuditLogger.log(
      log_type: "member",
      event_type: "invoice_settled",
      resource_type: "Invoice",
      resource_id: invoice.id,
      subject: invoice.member,
      after_snapshot: snapshot,
      message_details: message_details
    )
  end

  def self.log_unmatched_payment(transaction, notification, related_resource, resource_class, resource_id, notification_record = nil)
    member = related_resource.is_a?(Member) ? related_resource : related_resource&.try(:member)
    details = payment_log_details(transaction, nil, member&.id)
    audit_resource = related_resource || notification_record
    audit_resource_type = audit_resource&.class&.name || resource_class.to_s.classify
    audit_resource_id = audit_resource&.id || resource_id
    message = "No open invoice matched Braintree payment #{transaction.id} for " \
      "#{resource_class} #{resource_id || 'unknown'} with amount $#{format('%.2f', transaction.amount.to_d)}."

    ::Service::AuditLogger.log(
      log_type: "member",
      event_type: "braintree_payment_unmatched",
      resource_type: audit_resource_type,
      resource_id: audit_resource_id,
      subject: member,
      after_snapshot: details,
      message_details: message
    )
    Rails.logger.warn("[BraintreeTransaction] #{message} payload=#{details.to_json} kind=#{notification.kind}")
    enque_message(
      "<!channel> ⚠️ #{message}",
      ::Service::SlackConnector.logs_channel
    )
  end

  def self.log_order_id_ownership_mismatch(transaction, notification, order_id_invoice, member, notification_record = nil)
    details = payment_log_details(transaction, nil, member&.id)
    details[:invoice] = {
      description: order_id_invoice.description,
      id: order_id_invoice.id.to_s,
      resourceClass: order_id_invoice.resource_class,
      subscriptionId: order_id_invoice.subscription_id,
      dueDate: order_id_invoice.due_date,
      planId: order_id_invoice.plan_id,
      memberId: order_id_invoice.member_id.to_s
    }
    resolved_member = member ? "member #{member.id}" : "no known member"
    message = "Braintree transaction #{transaction.id} order_id resolved to Braintree invoice ID: #{order_id_invoice.id} " \
      "(resource class: #{order_id_invoice.resource_class}) " \
      "owned by member #{order_id_invoice.member_id}, but the transaction's customer resolved to " \
      "#{resolved_member}. Ignoring the order_id match."

    ::Service::AuditLogger.log(
      log_type: "member",
      event_type: "braintree_order_id_ownership_mismatch",
      resource_type: "Invoice",
      resource_id: order_id_invoice.id,
      subject: member || order_id_invoice.member,
      after_snapshot: details,
      message_details: message
    )
    Rails.logger.warn("[BraintreeTransaction] #{message} payload=#{details.to_json} kind=#{notification.kind}")
    enque_message(
      "<!channel> ⚠️ #{message}",
      ::Service::SlackConnector.logs_channel
    )
  end

  def self.payment_log_details(transaction, invoice = nil, member_id = nil)
    customer_details = transaction.try(:customer_details)
    member = invoice&.member

    {
      incomingPayment: {
        status: transaction.try(:status),
        planId: transaction.try(:plan_id),
        subscriptionId: transaction.try(:subscription_id),
        amount: transaction.try(:amount)&.to_d&.to_f,
        memberId: (member&.id || member_id)&.to_s,
        customerDetails: {
          id: customer_details.try(:id),
          first_name: customer_details.try(:first_name),
          last_name: customer_details.try(:last_name)
        }
      },
      invoice: invoice && {
        description: invoice.description,
        id: invoice.id.to_s,
        resourceClass: invoice.resource_class,
        subscriptionId: invoice.subscription_id,
        dueDate: invoice.due_date,
        planId: invoice.plan_id
      }
    }
  end

  def self.member_for_transaction(transaction)
    customer_id = transaction.try(:customer_details).try(:id)
    Member.find_by(customer_id: customer_id) if customer_id.present?
  end

  def self.member_for_subscription(resource_class, resource_id, transaction)
    member = member_for_transaction(transaction)
    return member if member

    resource = Invoice.resource(resource_class, resource_id)
    resource.is_a?(Member) ? resource : resource&.try(:member)
  end

  def self.invoice_match_amount(transaction)
    BigDecimal(transaction.try(:amount).to_s) + transaction_discount_total(transaction)
  rescue ArgumentError
    transaction.try(:amount)
  end

  def self.find_invoice_matching_transaction_amount(transaction)
    net_amount = BigDecimal(transaction.try(:amount).to_s)
    amounts = [net_amount, invoice_match_amount(transaction)].uniq

    amounts.each do |amount|
      invoice = yield(amount)
      return invoice if invoice
    end

    nil
  rescue ArgumentError
    yield(transaction.try(:amount))
  end

  def self.transaction_discount_total(transaction)
    transaction_discounts(transaction).sum(BigDecimal("0")) do |discount|
      quantity = discount.try(:quantity).presence || 1
      BigDecimal(discount.try(:amount).to_s) * quantity.to_i
    end
  rescue ArgumentError
    BigDecimal("0")
  end

  def self.transaction_discounts(transaction)
    discounts = transaction.try(:discounts)
    discounts.respond_to?(:to_a) ? discounts.to_a : Array(discounts)
  end

  def self.discount_confirmed_match?(invoice, transaction)
    discount_total = transaction_discount_total(transaction)
    return false unless discount_total.positive?

    invoice_amount = BigDecimal(invoice.amount.to_s)
    settled_amount = BigDecimal(transaction.amount.to_s)
    invoice_amount != settled_amount && invoice_amount == settled_amount + discount_total
  rescue ArgumentError
    false
  end

  def self.prior_sub_notification_for_resource(resource)
    BraintreeService::Notification.where(payload: /#{resource.id}/)
  end

  def self.get_member_profile(member)
    base_url = Rails.configuration.x.app_base_url
    "<#{base_url}/members/#{member.id}|#{member.fullname}>"
  end
end
