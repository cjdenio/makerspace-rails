require 'rails_helper'

RSpec.describe BraintreeService::Notification, type: :model do
  let(:gateway) { double } # Create a fake gateway
  let(:member) { create(:member) }
  let(:invoice) { create(:invoice, member: member, subscription_id: "some_id") }
  let(:subscription) { build(:subscription, id: invoice.generate_subscription_id) }
  let(:transaction) { build(:transaction, id: "foo") }

  let(:pd_transaction) { build(:transaction, id: "bar") }

  let(:successful_charge_notification) { double(kind: ::Braintree::WebhookNotification::Kind::SubscriptionChargedSuccessfully, subscription: subscription, timestamp: Time.now) }
  let(:failed_transaction_notification) { double(kind: ::Braintree::WebhookNotification::Kind::TransactionSettlementDeclined, transaction: pd_transaction, timestamp: Time.now) }
  let(:success_transaction_notification) { double(kind: ::Braintree::WebhookNotification::Kind::TransactionSettled, transaction: transaction, timestamp: Time.now) }
  let(:incoming_dispute_notification) { double(kind: ::Braintree::WebhookNotification::Kind::DisputeOpened, dispute: dispute, timestamp: Time.now) }
  let(:dispute) { build(:dispute) }

  describe "Mongoid validations" do
    it { is_expected.to be_mongoid_document }
    it { is_expected.to be_stored_in(collection: 'braintree__notifications') }

    it { is_expected.to have_fields(:kind, :payload).of_type(String) }
    it { is_expected.to have_field(:timestamp).of_type(Date) }
  end

  it "has a factory" do
    expect(build(:notification)).to be_truthy
  end

  describe "#process" do
    before(:each) do
      allow(successful_charge_notification).to receive_message_chain(:subscription, :id).and_return(subscription.id)
      allow(successful_charge_notification).to receive_message_chain(:subscription, :transactions, :first).and_return(transaction)
    end

    it "reads notification and stores in db" do
      expect {
        BraintreeService::Notification.process(successful_charge_notification)
      }.to change(BraintreeService::Notification, :count).by(1)

      payload = JSON.parse(BraintreeService::Notification.desc(:id).first.payload)
      expect(payload.fetch("incomingPayment").keys).to contain_exactly(
        "status", "planId", "subscriptionId", "amount", "memberId", "customerDetails"
      )
    end

    it "associates an unmatched customerless transaction audit with its stored notification" do
      customer_details = double(
        id: "unknown-braintree-customer",
        first_name: "Unknown",
        last_name: "Customer"
      )
      allow(transaction).to receive(:customer_details).and_return(customer_details)
      allow(transaction).to receive(:subscription_id).and_return(nil)
      allow(transaction).to receive(:order_id).and_return(nil)
      allow(BraintreeService::Notification).to receive(:member_for_transaction).and_return(nil)
      allow(BraintreeService::Notification).to receive(:enque_message)

      BraintreeService::Notification.process(success_transaction_notification)

      notification_record = BraintreeService::Notification.desc(:id).first
      audit_log = AuditLog.find_by(event_type: "braintree_payment_unmatched")
      expect(audit_log.resource_type).to eq("BraintreeService::Notification")
      expect(audit_log.resource_id).to eq(notification_record.id)
      expect(audit_log.after_snapshot.dig("incomingPayment", "customerDetails")).to eq(
        "id" => "unknown-braintree-customer",
        "first_name" => "Unknown",
        "last_name" => "Customer"
      )
    end

    it "processes subscription payment" do
      expect(BraintreeService::Notification).to receive(:process_subscription_charge_success).with(invoice, transaction)
      BraintreeService::Notification.process(successful_charge_notification)
    end

    it "scopes subscription plan fallback to the Braintree customer member" do
      member.update!(customer_id: "bt-customer-plan")
      allow(transaction).to receive(:customer_details).and_return(
        double(id: "bt-customer-plan", first_name: nil, last_name: nil)
      )
      expect(Invoice).to receive(:oldest_active_subscription_invoice_matching_amount).with(
        hash_including(member_id: member.id)
      ).and_return(invoice)
      expect(BraintreeService::Notification).to receive(:process_subscription_charge_success).with(invoice, transaction)

      BraintreeService::Notification.process(successful_charge_notification)
    end

    it "falls back to the amount before discounts when the net amount does not match" do
      discount = double(amount: "3.25", quantity: 2, name: "Member discount")
      allow(transaction).to receive(:amount).and_return(BigDecimal("58.50"))
      allow(transaction).to receive(:discounts).and_return([discount])
      expect(Invoice).to receive(:oldest_active_subscription_invoice_matching_amount).with(
        hash_including(amount: BigDecimal("58.50"))
      ).ordered.and_return(nil)
      expect(Invoice).to receive(:oldest_active_subscription_invoice_matching_amount).with(
        hash_including(amount: BigDecimal("65.00"))
      ).ordered.and_return(invoice)
      expect(BraintreeService::Notification).to receive(:process_subscription_charge_success).with(invoice, transaction)

      BraintreeService::Notification.process(successful_charge_notification)
    end

    it "matches the net transaction amount before adding applied discounts" do
      discount = double(amount: "3.25", quantity: 2, name: "Member discount")
      allow(transaction).to receive(:amount).and_return(BigDecimal("58.50"))
      allow(transaction).to receive(:discounts).and_return([discount])
      expect(Invoice).to receive(:oldest_active_subscription_invoice_matching_amount).with(
        hash_including(amount: BigDecimal("58.50"))
      ).once.and_return(invoice)
      expect(BraintreeService::Notification).to receive(:process_subscription_charge_success).with(invoice, transaction)

      BraintreeService::Notification.process(successful_charge_notification)
    end

    it "processes subscription payment failure" do
      failure = double(kind: ::Braintree::WebhookNotification::Kind::SubscriptionChargedUnsuccessfully, subscription: subscription, timestamp: Time.now)
      allow(failure).to receive_message_chain(:subscription, :id).and_return(subscription.id)
      allow(failure).to receive_message_chain(:subscription, :transactions, :first).and_return(transaction)
      expect(BraintreeService::Notification).to receive(:process_subscription_charge_failure).with(invoice, transaction)
      BraintreeService::Notification.process(failure)
    end

    it "processes a failed subscription payment without an exact amount match" do
      failure = double(
        kind: ::Braintree::WebhookNotification::Kind::SubscriptionChargedUnsuccessfully,
        subscription: subscription,
        timestamp: Time.now
      )
      allow(failure).to receive_message_chain(:subscription, :id).and_return(subscription.id)
      allow(failure).to receive_message_chain(:subscription, :transactions, :first).and_return(transaction)
      allow(Invoice).to receive(:oldest_active_subscription_invoice_matching_amount).and_return(nil)

      expect(BraintreeService::Notification).to receive(:process_subscription_charge_failure).with(invoice, transaction)

      BraintreeService::Notification.process(failure)
    end

    it "processes subscription cancellation" do
      cancellation = double(kind: ::Braintree::WebhookNotification::Kind::SubscriptionCanceled, subscription: subscription, timestamp: Time.now)
      expect(BraintreeService::Notification).to receive(:process_subscription_cancellation).with(invoice)
      BraintreeService::Notification.process(cancellation)
    end

    it "processes dispute" do
      expect(BraintreeService::Notification).to receive(:process_dispute).with(incoming_dispute_notification)
      BraintreeService::Notification.process(incoming_dispute_notification)
    end
  end

  describe "#get_details_for_notification" do
    it "includes the owning member ID for a rental subscription" do
      rental = create(:rental, member: member)
      rental_subscription = double(
        id: "rental_#{rental.id}_invoice",
        transactions: [transaction]
      )
      notification = double(
        kind: ::Braintree::WebhookNotification::Kind::SubscriptionChargedSuccessfully,
        subscription: rental_subscription
      )

      details = BraintreeService::Notification.get_details_for_notification(notification)

      expect(details.dig(:incomingPayment, :memberId)).to eq(member.id.to_s)
    end

    it "includes the owning member ID for a household subscription" do
      household = create(:group, member: member)
      household_subscription = double(
        id: "household_#{household.id}_invoice",
        transactions: [transaction]
      )
      notification = double(
        kind: ::Braintree::WebhookNotification::Kind::SubscriptionChargedSuccessfully,
        subscription: household_subscription
      )

      details = BraintreeService::Notification.get_details_for_notification(notification)

      expect(details.dig(:incomingPayment, :memberId)).to eq(member.id.to_s)
    end

    it "persists a late subscription notification when its resource has been deleted" do
      rental = create(:rental, member: member)
      resource_id = rental.id
      rental.destroy!
      allow(transaction).to receive(:customer_details).and_return(nil)
      late_subscription = double(
        id: "rental_#{resource_id}_invoice",
        plan_id: "rental-plan",
        transactions: [transaction]
      )
      notification = double(
        kind: ::Braintree::WebhookNotification::Kind::SubscriptionChargedSuccessfully,
        subscription: late_subscription,
        timestamp: Time.current
      )
      allow(BraintreeService::Notification).to receive(:enque_message)

      expect {
        BraintreeService::Notification.process(notification)
      }.to change(BraintreeService::Notification, :count).by(1)

      notification_record = BraintreeService::Notification.desc(:id).first
      payload = JSON.parse(notification_record.payload)
      expect(payload.dig("incomingPayment", "memberId")).to be_nil
      expect(AuditLog.find_by(event_type: "braintree_payment_unmatched").resource_id).to eq(notification_record.id)
    end
  end

  describe "#process subscription" do
    before(:each) do
      allow(successful_charge_notification).to receive_message_chain(:subscription, :transactions, :first).and_return(transaction)
    end

    it "Settles invoice and renews resource" do
      create(:card, member: member)
      init_member_expiration = member.pretty_time
      allow(transaction).to receive(:line_items).and_return([])
      allow(transaction).to receive(:customer_details).and_return(
        double(id: "bt-customer-1", first_name: "Paid", last_name: "Member")
      )
      expect(BraintreeService::Notification).to receive(:enque_message).with(/recurring payment/i)

      BraintreeService::Notification.process_subscription(successful_charge_notification)
      member.reload
      invoice.reload
      expect(invoice.settled).to be_truthy
      expect(member.pretty_time.to_i).to be > (init_member_expiration.to_i)
      expect(invoice.transaction_id).to eq(transaction.id)

      audit_log = AuditLog.find_by(event_type: "invoice_settled", resource_id: invoice.id)
      expect(audit_log).to be_present
      expect(audit_log.slack_message).to include(
        "Braintree invoice ID: #{invoice.id}",
        "resource class: #{invoice.resource_class}"
      )
      expect(audit_log.after_snapshot.dig("incomingPayment", "status")).to eq(transaction.status)
      expect(audit_log.after_snapshot.dig("incomingPayment", "amount")).to eq(transaction.amount.to_f)
      expect(audit_log.after_snapshot.dig("incomingPayment", "memberId")).to eq(member.id.to_s)
      expect(audit_log.after_snapshot.dig("incomingPayment", "customerDetails", "id")).to eq("bt-customer-1")
      expect(audit_log.after_snapshot.dig("incomingPayment", "customerDetails", "first_name")).to eq("Paid")
      expect(audit_log.after_snapshot.dig("incomingPayment", "customerDetails", "last_name")).to eq("Member")
      expect(audit_log.after_snapshot.fetch("incomingPayment").keys).to contain_exactly(
        "status", "planId", "subscriptionId", "amount", "memberId", "customerDetails"
      )
      expect(audit_log.after_snapshot.dig("invoice", "id")).to eq(invoice.id.to_s)
      expect(audit_log.after_snapshot.dig("invoice", "description")).to eq(invoice.description)
      expect(audit_log.after_snapshot.fetch("invoice").keys).to contain_exactly(
        "description", "id", "resourceClass", "subscriptionId", "dueDate", "planId"
      )
    end


    it "applies a payment to the oldest open invoice with an equal numeric amount" do
      older_invoice = invoice
      older_invoice.update!(created_at: 2.days.ago, amount: 65.0)
      newer_invoice = build(
        :invoice,
        member: member,
        resource_id: member.id,
        resource_class: "member",
        amount: 65.0,
        created_at: 1.day.ago
      )
      newer_invoice.save!(validate: false)
      allow(transaction).to receive(:amount).and_return(BigDecimal("65.00"))
      allow(transaction).to receive(:line_items).and_return([])
      allow(BraintreeService::Notification).to receive(:enque_message)

      BraintreeService::Notification.process_subscription(successful_charge_notification)

      expect(older_invoice.reload.transaction_id).to eq(transaction.id)
      expect(newer_invoice.reload.transaction_id).to be_nil
    end

    it "does not fall through to a same-resource-id fee invoice when subscription ID matching misses" do
      # Forces subscription_id (tier 1) and plan_id (tier 2) to miss so the
      # resource_id-only fallback (tier 3) is what actually gets exercised.
      # invoice.subscription_id stays "some_id" from the top-level let, which
      # never equals the incoming composite subscription id, so this proves
      # the resource_class scoping fix in the fallback tier itself — not just
      # a tier-1 subscription_id match that happens to avoid the fallback.
      fee_invoice = create(
        :invoice,
        member: member,
        resource_class: "fee",
        resource_id: member.id,
        amount: 65.0,
        created_at: 3.days.ago
      )
      invoice.update!(created_at: 1.day.ago, amount: 65.0)
      allow(transaction).to receive(:amount).and_return(BigDecimal("65.00"))
      allow(transaction).to receive(:line_items).and_return([])
      allow(BraintreeService::Notification).to receive(:enque_message)

      BraintreeService::Notification.process_subscription(successful_charge_notification)

      expect(invoice.reload.transaction_id).to eq(transaction.id)
      expect(fee_invoice.reload.transaction_id).to be_nil
    end

    it "settles the member's subscription invoice instead of a same-resource-id fee invoice" do
      # Reproduces a production incident: a fee invoice (resource_class "fee")
      # shares resource_id with a member's open subscription invoice because
      # fee invoices store resource_id == member_id. A resource_id-only match
      # would settle whichever invoice Mongo returns first; the subscription_id
      # tier must win regardless.
      fee_invoice = create(
        :invoice,
        member: member,
        resource_class: "fee",
        resource_id: member.id,
        amount: 65.0,
        created_at: 3.days.ago
      )
      invoice.update!(subscription_id: subscription.id, created_at: 1.day.ago, amount: 65.0)
      allow(transaction).to receive(:amount).and_return(BigDecimal("65.00"))
      allow(transaction).to receive(:line_items).and_return([])
      allow(BraintreeService::Notification).to receive(:enque_message)

      BraintreeService::Notification.process_subscription(successful_charge_notification)

      expect(invoice.reload.transaction_id).to eq(transaction.id)
      expect(fee_invoice.reload.transaction_id).to be_nil
    end

    it "Skips settlement if invoice is already in progress" do
      InvoiceHelper.update_lifecycle(invoice.id, InvoiceHelper::LIFECYCLES[:InProgress])
      create(:card, member: member)
      init_member_expiration = member.pretty_time
      allow(transaction).to receive(:line_items).and_return([])
      expect(BraintreeService::Notification).to receive(:enque_message).with(/in-progress invoice/i, "treasurer")

      BraintreeService::Notification.process_subscription(successful_charge_notification)
      member.reload
      invoice.reload
      expect(invoice.settled).to be_falsy
      expect(member.pretty_time.to_i).to eq(init_member_expiration.to_i)
    end

    it "Reports error if no subscription is found" do
      allow(successful_charge_notification).to receive_message_chain(:subscription).and_return(nil)
      expect(BraintreeService::Notification).to receive(:enque_message).with(/malformed subscription/i)
      BraintreeService::Notification.get_details_for_notification(successful_charge_notification)
    end

    it "reports error if no invoice is found" do
      allow(Invoice).to receive(:oldest_active_subscription_invoice_matching_amount).and_return(nil)
      expect(BraintreeService::Notification).to receive(:enque_message).with(/<!channel>.*no open invoice matched/i, "interface-logs")

      BraintreeService::Notification.process_subscription(successful_charge_notification)

      audit_log = AuditLog.find_by(event_type: "braintree_payment_unmatched")
      expect(audit_log).to be_present
      expect(audit_log.after_snapshot.dig("incomingPayment", "status")).to eq(transaction.status)
      expect(audit_log.after_snapshot.dig("incomingPayment", "amount")).to eq(transaction.amount.to_f)
    end

    it "reports error if no resource is found" do
      allow(Invoice).to receive(:oldest_active_subscription_invoice_matching_amount).and_return(invoice)
      allow_any_instance_of(Invoice).to receive(:submit_for_settlement).and_raise(Error::NotFound)
      allow(successful_charge_notification).to receive_message_chain(:subscription, :transactions, :first).and_return(transaction)
      allow(BraintreeService::Notification).to receive(:enque_message).with(/processing invoice/i)
      expect(BraintreeService::Notification).to receive(:enque_message).with(/unknown resource/i)
      BraintreeService::Notification.process_subscription(successful_charge_notification)
    end

    it "reports error if unable to renew resource" do
      allow(Invoice).to receive(:oldest_active_subscription_invoice_matching_amount).and_return(invoice)
      allow_any_instance_of(Invoice).to receive(:submit_for_settlement).and_raise(Error::UnprocessableEntity, "Some error")
      allow(successful_charge_notification).to receive_message_chain(:subscription, :transactions, :first).and_return(transaction)
      allow(BraintreeService::Notification).to receive(:enque_message).with(/processing invoice/i)
      expect(BraintreeService::Notification).to receive(:enque_message).with(/some error/i)
      BraintreeService::Notification.process_subscription(successful_charge_notification)
    end

    it "claims a subscription invoice before processing a successful charge" do
      allow(InvoiceHelper).to receive(:get_lifecycle).and_return(nil)
      allow(InvoiceHelper).to receive(:pay_workflow) { |_invoice_id, workflow| workflow.call }
      allow(BraintreeService::Notification).to receive(:process_success)

      expect(Invoice).to receive(:claim_for_transaction).with(invoice.id, transaction.id).and_call_original

      BraintreeService::Notification.send(:process_subscription_charge_success, invoice, transaction)

      expect(BraintreeService::Notification).to have_received(:process_success).with(
        an_object_having_attributes(id: invoice.id, transaction_id: transaction.id),
        transaction
      )
      expect(invoice.reload.locked).to be(false)
    end

    it "does not process a subscription invoice claimed by another webhook" do
      allow(InvoiceHelper).to receive(:get_lifecycle).and_return(nil)
      allow(Invoice).to receive(:claim_for_transaction).with(invoice.id, transaction.id).and_return(nil)
      allow(BraintreeService::Notification).to receive(:enque_message)

      expect(BraintreeService::Notification).not_to receive(:process_success)

      BraintreeService::Notification.send(:process_subscription_charge_success, invoice, transaction)

      expect(BraintreeService::Notification).to have_received(:enque_message).with(
        /duplicate.*claimed invoice/i,
        "treasurer"
      )
    end

    it "links a failed charge to the invoice without touching transaction_id" do
      allow(BraintreeService::Notification).to receive(:enque_message)
      allow(BillingMailer).to receive_message_chain(:failed_payment, :deliver_later)

      BraintreeService::Notification.send(:process_subscription_charge_failure, invoice, transaction)

      invoice.reload
      expect(invoice.last_failed_transaction_id).to eq(transaction.id)
      expect(invoice.transaction_id).to be_nil
    end

    it "still lets a later successful charge claim the invoice after a prior failure" do
      allow(BraintreeService::Notification).to receive(:enque_message)
      allow(BillingMailer).to receive_message_chain(:failed_payment, :deliver_later)
      BraintreeService::Notification.send(:process_subscription_charge_failure, invoice, pd_transaction)
      invoice.reload
      expect(invoice.last_failed_transaction_id).to eq(pd_transaction.id)

      claimed = Invoice.claim_for_transaction(invoice.id, transaction.id)

      expect(claimed).to be_present
      expect(claimed.transaction_id).to eq(transaction.id)
    end

    it "does not audit settlement when invoice processing is delayed" do
      allow(BraintreeService::Notification).to receive(:enque_message)
      allow(invoice).to receive(:submit_for_settlement)
      allow(invoice).to receive(:reload).and_return(invoice)
      allow(invoice).to receive(:settled).and_return(false)
      allow(BillingMailer).to receive_message_chain(:receipt, :deliver_later)

      expect(BraintreeService::Notification).not_to receive(:log_invoice_settled)

      BraintreeService::Notification.send(:process_success, invoice, transaction)

      expect(invoice.reload.settlement_processed_at).to be_present
    end
  end

  describe "#process_dispute" do
    let(:member) { create(:member) }
    let(:invoice) { create(:invoice, member: member, transaction_id: "foo") }
    let(:notification) { double(kind: ::Braintree::WebhookNotification::Kind::DisputeOpened, dispute: dispute) }
    let(:transaction) { build(:transaction, id: "foo") }

    it "Notifies and sets invoice to dispute requested" do
      invoice # Call to initialize
      allow(notification).to receive_message_chain(:dispute, :transaction).and_return(transaction)
      allow(transaction).to receive(:line_items).and_return([])
      expect(BraintreeService::Notification).to receive(:enque_message).with(/received dispute/i)

      BraintreeService::Notification.process_dispute(notification)
      invoice.reload
      expect(invoice.dispute_requested).to be_truthy
    end

    it "Reports error if no transaction is found" do
      allow(notification).to receive(:dispute).and_return(nil)
      expect(BraintreeService::Notification).to receive(:enque_message).with(/malformed dispute/i)
      BraintreeService::Notification.get_details_for_notification(notification)
    end

    it "reports error if no invoice is found" do
      allow(notification).to receive_message_chain(:dispute, :transaction).and_return(transaction)
      allow(Invoice).to receive(:active_invoice_for_resource).and_return(nil)
      expect(BraintreeService::Notification).to receive(:enque_message).with(/cannot find related invoice/i)
      BraintreeService::Notification.process_dispute(notification)
    end
  end

  describe "#process_transaction" do 
    before(:each) do
      allow(failed_transaction_notification).to receive(:transaction).and_return(pd_transaction)
    end

    it "unsettles a processed invoice and un-renews its resource on failure" do
      new_member = create(:member)
      settled_invoice = create(
        :invoice,
        member: new_member,
        transaction_id: pd_transaction.id,
        settlement_processed_at: 1.minute.ago
      )
      create(:card, member: new_member)
      new_member.reload
      init_member_expiration = new_member.pretty_time
      allow(pd_transaction).to receive(:line_items).and_return([])
      expect(BraintreeService::Notification).to receive(:enque_message).with(/failed with status/i, anything, anything)

      BraintreeService::Notification.process_transaction(failed_transaction_notification)
      new_member.reload
      settled_invoice.reload
      expect(settled_invoice.settled).to be_falsy
      expect(new_member.pretty_time.to_i).to be < (init_member_expiration.to_i)
      expect(settled_invoice.transaction_id).to eq(pd_transaction.id)
    end

    it "defers a settlement decline while successful charge processing holds the invoice claim" do
      claimed_invoice = create(
        :invoice,
        transaction_id: pd_transaction.id,
        locked: true,
        locked_at: Time.current
      )

      expect {
        BraintreeService::Notification.process_transaction(failed_transaction_notification)
      }.to raise_error(Error::Conflict, /waiting for active invoice processing/i)

      expect(claimed_invoice.reload.locked).to be(true)
    end

    it "reports error if no invoice is found" do
      allow(Invoice).to receive(:active_invoice_for_resource).and_return(nil)
      expect(BraintreeService::Notification).to receive(:enque_message).with(/no invoice found/i)
      BraintreeService::Notification.process_transaction(failed_transaction_notification)
    end

    it "Settles invoice on success if not already settled" do 
      new_member = create(:member)
      create(:card, member: new_member)
      settled_invoice = create(:invoice, member: new_member, transaction_id: transaction.id) 
      init_member_expiration = new_member.pretty_time
      allow(transaction).to receive(:line_items).and_return([])
      expect(BraintreeService::Notification).to receive(:enque_message).with(/one-time payment/i)

      BraintreeService::Notification.process_transaction(success_transaction_notification)
      new_member.reload
      settled_invoice.reload
      expect(settled_invoice.settled).to be_truthy
      expect(new_member.pretty_time.to_i).to be > (init_member_expiration.to_i)
    end


    it "matches an unassigned settled transaction to the member's oldest equal-amount rental invoice" do
      new_member = create(:member, customer_id: "bt-customer-1")
      rental = create(:rental, member: new_member)
      older_invoice = create(
        :invoice,
        member: new_member,
        resource_class: "rental",
        resource_id: rental.id,
        amount: 65.0,
        created_at: 2.days.ago
      )
      newer_invoice = create(
        :invoice,
        member: new_member,
        resource_class: "rental",
        resource_id: rental.id,
        amount: 65.0,
        created_at: 1.day.ago
      )
      allow(transaction).to receive(:customer_details).and_return(
        double(id: "bt-customer-1", first_name: new_member.firstname, last_name: new_member.lastname)
      )
      allow(transaction).to receive(:amount).and_return(BigDecimal("65.00"))
      allow(transaction).to receive(:line_items).and_return([])
      allow(BraintreeService::Notification).to receive(:enque_message)

      BraintreeService::Notification.process_transaction(success_transaction_notification)

      expect(older_invoice.reload.transaction_id).to eq(transaction.id)
      expect(newer_invoice.reload.transaction_id).to be_nil
    end

    it "does not settle an order_id-matched invoice owned by a different member" do
      owner = create(:member, customer_id: "bt-owner")
      payer = create(:member, customer_id: "bt-other-payer")
      owners_invoice = create(:invoice, member: owner, amount: 65.0, created_at: 2.days.ago)
      payers_invoice = create(:invoice, member: payer, amount: 65.0, created_at: 1.day.ago)
      allow(transaction).to receive(:customer_details).and_return(
        double(id: "bt-other-payer", first_name: payer.firstname, last_name: payer.lastname)
      )
      allow(transaction).to receive(:order_id).and_return(owners_invoice.id.to_s)
      allow(transaction).to receive(:amount).and_return(BigDecimal("65.00"))
      allow(transaction).to receive(:line_items).and_return([])
      allow(BraintreeService::Notification).to receive(:enque_message)

      BraintreeService::Notification.process_transaction(success_transaction_notification)

      expect(owners_invoice.reload.transaction_id).to be_nil
      expect(payers_invoice.reload.transaction_id).to eq(transaction.id)

      audit_log = AuditLog.find_by(event_type: "braintree_order_id_ownership_mismatch")
      expect(audit_log).to be_present
      expect(audit_log.resource_id).to eq(owners_invoice.id)
      expect(audit_log.after_snapshot.dig("invoice", "memberId")).to eq(owner.id.to_s)
      expect(audit_log.after_snapshot.dig("incomingPayment", "memberId")).to eq(payer.id.to_s)
    end

    it "matches a non-subscription settlement by Braintree order ID before amount fallback" do
      new_member = create(:member, customer_id: "bt-customer-order")
      create(:card, member: new_member)
      target_invoice = create(:invoice, member: new_member, amount: 65.0, created_at: 1.day.ago)
      allow(transaction).to receive(:customer_details).and_return(
        double(id: "bt-customer-order", first_name: new_member.firstname, last_name: new_member.lastname)
      )
      allow(transaction).to receive(:order_id).and_return(target_invoice.id.to_s)
      allow(transaction).to receive(:amount).and_return(BigDecimal("65.00"))
      allow(transaction).to receive(:line_items).and_return([])
      allow(BraintreeService::Notification).to receive(:enque_message)

      BraintreeService::Notification.process_transaction(success_transaction_notification)

      expect(target_invoice.reload.transaction_id).to eq(transaction.id)
    end

    it "matches a discounted settlement and audits the credited discounts" do
      new_member = create(:member, customer_id: "bt-customer-discount")
      create(:card, member: new_member)
      new_member.reload
      discounted_invoice = create(:invoice, member: new_member, amount: 65.0, plan_id: "member-plan")
      discount = double(
        amount: "3.25",
        quantity: 2,
        name: "Monthly membership discount"
      )
      allow(transaction).to receive(:customer_details).and_return(
        double(id: "bt-customer-discount", first_name: new_member.firstname, last_name: new_member.lastname)
      )
      allow(transaction).to receive(:amount).and_return(BigDecimal("58.50"))
      allow(transaction).to receive(:discounts).and_return([discount])
      allow(transaction).to receive(:line_items).and_return([])
      allow(BraintreeService::Notification).to receive(:enque_message)

      BraintreeService::Notification.process_transaction(success_transaction_notification)

      audit_log = AuditLog.find_by(event_type: "invoice_settled", resource_id: discounted_invoice.id)
      expect(discounted_invoice.reload.transaction_id).to eq(transaction.id)
      expect(audit_log.after_snapshot.dig("discountMatch", "memberId")).to eq(new_member.id.to_s)
      expect(audit_log.after_snapshot.dig("discountMatch", "planId")).to eq("member-plan")
      expect(audit_log.after_snapshot.dig("discountMatch", "invoiceId")).to eq(discounted_invoice.id.to_s)
      expect(audit_log.after_snapshot.dig("discountMatch", "totalDiscountApplied")).to eq(6.5)
      expect(audit_log.after_snapshot.dig("discountMatch", "discounts")).to eq(
        ["Monthly membership discount: $6.50"]
      )
      expect(audit_log.slack_message).to include("total discount $6.50")
    end

    it "matches a subscription settlement by subscription ID before older equal-amount invoices" do
      new_member = create(:member, customer_id: "bt-customer-subscription")
      create(:card, member: new_member)
      rental = create(:rental, member: new_member)
      rental_invoice = create(
        :invoice,
        member: new_member,
        resource_class: "rental",
        resource_id: rental.id,
        amount: 65.0,
        created_at: 2.days.ago
      )
      subscription_id = "member_#{new_member.id}_subscription"
      membership_invoice = create(
        :invoice,
        member: new_member,
        resource_class: "member",
        resource_id: new_member.id,
        subscription_id: subscription_id,
        amount: 65.0,
        created_at: 1.day.ago
      )
      allow(transaction).to receive(:customer_details).and_return(
        double(id: "bt-customer-subscription", first_name: new_member.firstname, last_name: new_member.lastname)
      )
      allow(transaction).to receive(:subscription_id).and_return(subscription_id)
      allow(transaction).to receive(:amount).and_return(BigDecimal("65.00"))
      allow(transaction).to receive(:line_items).and_return([])
      allow(BraintreeService::Notification).to receive(:enque_message)

      BraintreeService::Notification.process_transaction(success_transaction_notification)

      expect(membership_invoice.reload.transaction_id).to eq(transaction.id)
      expect(rental_invoice.reload.transaction_id).to be_nil
    end


    it "does not process an invoice when another delivery claims it first" do
      new_member = create(:member, customer_id: "bt-customer-concurrent")
      open_invoice = create(:invoice, member: new_member, amount: 65.0)
      allow(transaction).to receive(:customer_details).and_return(
        double(id: "bt-customer-concurrent", first_name: new_member.firstname, last_name: new_member.lastname)
      )
      allow(transaction).to receive(:amount).and_return(BigDecimal("65.00"))
      allow(BraintreeService::Notification).to receive(:enque_message)
      allow(Invoice).to receive(:claim_for_transaction) do
        open_invoice.set(transaction_id: transaction.id, locked: true)
        nil
      end

      expect(BraintreeService::Notification).not_to receive(:process_success)

      BraintreeService::Notification.process_transaction(success_transaction_notification)

      expect(BraintreeService::Notification).to have_received(:enque_message).with(
        /duplicate.*claimed transaction/i,
        "treasurer"
      )
    end

    it "skips a concurrent delivery after an invoice has been claimed" do
      claimed_invoice = create(:invoice, transaction_id: transaction.id, locked: true, locked_at: Time.current)
      allow(BraintreeService::Notification).to receive(:enque_message)

      expect(BraintreeService::Notification).not_to receive(:process_success)

      BraintreeService::Notification.process_transaction(success_transaction_notification)

      expect(BraintreeService::Notification).to have_received(:enque_message).with(
        /duplicate.*claimed transaction/i,
        "treasurer"
      )
      expect(claimed_invoice.reload.settled).to be(false)
    end

    it "reclaims and processes an abandoned invoice claim" do
      new_member = create(:member)
      create(:card, member: new_member)
      new_member.reload
      abandoned_invoice = create(
        :invoice,
        member: new_member,
        transaction_id: transaction.id,
        locked: true,
        locked_at: 16.minutes.ago
      )
      allow(BraintreeService::Notification).to receive(:enque_message)
      expect(BraintreeService::Notification).to receive(:process_success).with(
        an_object_having_attributes(id: abandoned_invoice.id),
        transaction
      )

      BraintreeService::Notification.process_transaction(success_transaction_notification)

      abandoned_invoice.reload
      expect(abandoned_invoice.locked).to be(false)
      expect(abandoned_invoice.locked_at).to be_nil
    end

    it "stops retrying and logs an unmatched payment after exhausting claim attempts" do
      new_member = create(:member, customer_id: "bt-customer-retry-exhaustion")
      create(:invoice, member: new_member, amount: 65.0)
      allow(transaction).to receive(:customer_details).and_return(
        double(id: "bt-customer-retry-exhaustion", first_name: new_member.firstname, last_name: new_member.lastname)
      )
      allow(transaction).to receive(:amount).and_return(BigDecimal("65.00"))
      allow(transaction).to receive(:line_items).and_return([])
      allow(BraintreeService::Notification).to receive(:enque_message)
      allow(BraintreeService::Notification).to receive(:log_unmatched_payment).and_call_original
      allow(Invoice).to receive(:claim_for_transaction).and_return(nil)

      BraintreeService::Notification.process_transaction(success_transaction_notification)

      expect(Invoice).to have_received(:claim_for_transaction).exactly(3).times
      expect(BraintreeService::Notification).to have_received(:log_unmatched_payment).once
    end

    it "deterministically prefers the net amount when both net and gross amounts match different invoices" do
      new_member = create(:member, customer_id: "bt-customer-net-vs-gross")
      rental = create(:rental, member: new_member)
      net_invoice = create(:invoice, member: new_member, amount: 58.50, created_at: 2.days.ago)
      gross_invoice = create(
        :invoice,
        member: new_member,
        resource_class: "rental",
        resource_id: rental.id,
        amount: 65.00,
        created_at: 1.day.ago
      )
      discount = double(amount: "3.25", quantity: 2, name: "Member discount")
      allow(transaction).to receive(:customer_details).and_return(
        double(id: "bt-customer-net-vs-gross", first_name: new_member.firstname, last_name: new_member.lastname)
      )
      allow(transaction).to receive(:amount).and_return(BigDecimal("58.50"))
      allow(transaction).to receive(:discounts).and_return([discount])
      allow(transaction).to receive(:line_items).and_return([])
      allow(BraintreeService::Notification).to receive(:enque_message)

      BraintreeService::Notification.process_transaction(success_transaction_notification)

      expect(net_invoice.reload.transaction_id).to eq(transaction.id)
      expect(gross_invoice.reload.transaction_id).to be_nil
    end

    it "does not reprocess a delayed settlement already handled for the transaction" do
      delayed_invoice = create(
        :invoice,
        transaction_id: transaction.id,
        settled_at: nil,
        settlement_processed_at: 1.minute.ago
      )
      allow(BraintreeService::Notification).to receive(:enque_message)

      expect(BraintreeService::Notification).not_to receive(:process_success)

      BraintreeService::Notification.process_transaction(success_transaction_notification)

      expect(BraintreeService::Notification).to have_received(:enque_message).with(
        /duplicate.*processed transaction/i,
        "treasurer"
      )
      expect(delayed_invoice.reload.settled).to be(false)
    end
  end
end
