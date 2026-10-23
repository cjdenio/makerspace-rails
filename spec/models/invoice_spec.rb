require 'rails_helper'

RSpec.describe Invoice, type: :model do

  describe "Mongoid validations" do
    it { is_expected.to be_mongoid_document }
    it { is_expected.to be_stored_in(collection: 'invoices') }

    it { is_expected.to have_fields(:name,
                                    :description,
                                    :resource_id,
                                    :resource_class,
                                    :plan_id,
                                    :transaction_id,
                                    :last_failed_transaction_id,
                                    :subscription_id,
                                    :discount_id).of_type(String) }
    it { is_expected.to have_field(:amount).of_type(Float) }
    it { is_expected.to have_fields(:settled_at, :refund_requested).of_type(Time) }
    it { is_expected.to have_field(:due_date).of_type(nil) }
    it { is_expected.to have_field(:created_at).of_type(Time) }
    it "sets created_at properly" do
      # within 1 hour since initializatino times can vary
      expect(build(:invoice).created_at.to_i).to be_within(60 * 60).of(Time.now.to_i)
    end
    it { is_expected.to have_field(:quantity).of_type(Integer).with_default_value_of(1) }
    it { is_expected.to have_field(:refunded).of_type(Mongoid::Boolean).with_default_value_of(false) }
    it { is_expected.to have_field(:operation).of_type(String).with_default_value_of('renew=') }
  end

  describe "ActiveModel validations" do
    it { is_expected.to validate_numericality_of(:amount) }
    it { is_expected.to validate_numericality_of(:quantity) }
    it { is_expected.to validate_presence_of(:resource_id) }
    it { is_expected.to validate_presence_of(:due_date) }
  end

  it "has a valid factory" do
    expect(build(:invoice)).to be_valid
  end

  context "validation" do
    let(:member) { create(:member) }
    let(:rental) { create(:rental) }

    it "validates resource class" do
      member_invoice = build(:invoice, resource_class: "member", resource_id: member.id)
      other_invoice = build(:invoice, resource_class: "foo")
      other_2_invoice = build(:invoice, resource_class: nil)
      rental_invoice = build(:invoice, resource_class: "rental", resource_id: rental.id)
      expect(member_invoice).to be_valid
      expect(rental_invoice).to be_valid
      expect(other_invoice).to_not be_valid
      expect(other_2_invoice).to_not be_valid
    end

    it "validates operation" do
      renew_invoice = build(:invoice)
      renew_2_invoice = build(:invoice, operation: "renew=")
      other_invoice = build(:invoice, operation: "foo")
      other_2_invoice = build(:invoice, resource_class: nil)
      expect(renew_invoice).to be_valid
      expect(renew_2_invoice).to be_valid
      expect(other_invoice).to_not be_valid
      expect(other_2_invoice).to_not be_valid
    end

    describe "validates one active member invoice" do
      it "prevents users from creating duplicate membership" do
        first_invoice = build(
          :invoice, 
          member: member, 
          resource_id: member.id, 
          resource_class: "member",
          subscription_id: "foobar"
        )
        expect(first_invoice).to be_valid
        first_invoice.save
        second_invoice = build(
          :invoice, 
          member: member, 
          resource_id: member.id, 
          resource_class: "member"
        )
        expect(second_invoice).to_not be_valid
      end

      it "prevents duplicate unused member invoices without deleting the existing invoice" do
        first_invoice = create(
          :invoice, 
          member: member, 
          resource_id: member.id, 
          resource_class: "member",
        )
        second_invoice = build(
          :invoice, 
          member: member, 
          resource_id: member.id, 
          resource_class: "member"
        )
        expect(second_invoice).to_not be_valid
        expect(Invoice.where(resource_id: member.id).size).to eq(1)
        expect(Invoice.find(first_invoice.id)).to be_truthy
      end

      it "does not restrict to one per rental" do
        first_invoice = build(:invoice, member: member, resource_id: rental.id, resource_class: "rental")
        expect(first_invoice).to be_valid
        first_invoice.save
        second_invoice = build(:invoice, member: member, resource_id: rental.id, resource_class: "rental")
        expect(second_invoice).to be_valid
      end
    end

    it "validates resource exists on create" do
      rental_invoice = build(:invoice, member: member, resource_id: rental.id, resource_class: "rental")
      member_invoice = build(:invoice, member: member, resource_id: member.id, resource_class: "member")
      mixed_invoice = build(:invoice, member: member, resource_id: rental.id, resource_class: "member")
      expect(rental_invoice).to be_valid
      expect(member_invoice).to be_valid
      expect(mixed_invoice).to_not be_valid
      rental_invoice.save
      member_invoice.save 
      mixed_invoice.save 
      expect(rental_invoice).to be_persisted
      expect(member_invoice).to be_persisted
      expect(mixed_invoice).to_not be_persisted
    end

    it "Does not validate resource on update" do 
      rental_invoice = create(:invoice, member: member, resource_id: rental.id, resource_class: "rental")
      rental.destroy
      rental_invoice.update({ amount: 5.0 })
      expect(rental_invoice).to be_valid
      expect(rental_invoice.amount).to eq(5.0)
    end
  end

  context "public methods" do
    let(:member) { create(:member) }
    let(:rental) { create(:rental) }

    it "parses resource name correctly" do 
      member_invoice = create(:invoice, member: member)
      rental_invoice = create(:invoice, member: member, resource_id: rental.id, resource_class: "rental")
      expect(member_invoice.resource_name).to eq(member.fullname)
      expect(rental_invoice.resource_name).to eq(rental.number)
    end

    describe "settlement" do
      it "has getter and setter methods for settled" do
        invoice = create(:invoice)
        expect(invoice.settled).to be_falsey
        invoice.settled = true
        expect(invoice.settled).to be_truthy
      end

      it "does not overwrite settled time" do
        timestamp_before = Time.now
        invoice = create(:invoice)
        invoice.settled = true
        timestamp_after = Time.now
        expect(invoice.settled_at).to be > timestamp_before
        expect(invoice.settled_at).to be < timestamp_after

        invoice.settled = true # Set again and make sure it's not updated
        expect(invoice.settled_at).to be < timestamp_after
      end

      it "can be reset" do
        timestamp_before = Time.now
        invoice = create(:invoice)
        invoice.settled = true
        timestamp_after = Time.now
        expect(invoice.settled_at).to be > timestamp_before
        expect(invoice.settled_at).to be < timestamp_after

        invoice.settled = false
        expect(invoice.settled_at).to be_nil
        invoice.settled = true

        invoice.settled = true # Set again and make sure it's not updated
        expect(invoice.settled_at).to be > timestamp_after
      end

      describe "submit for settlement" do
        let(:gateway) { double } # Create a fake gateway
        let(:transaction) { double(id: "settlement-test-transaction") }
        let(:first_transaction) { build(:transaction) }
        let(:success_result) { double(success?: true) }
        let(:error_result) { double(success?: false) }
        let(:invoice) { create(:invoice, member: member) }

        it "Will create a new transaction if payment method ID provided" do
          allow(BraintreeService::Transaction).to receive(:submit_invoice_for_settlement).with(gateway, invoice).and_return(transaction)
          expect(BraintreeService::Transaction).to receive(:submit_invoice_for_settlement).with(gateway, invoice).and_return(transaction)
          expect(invoice).to receive(:settle_invoice)
          expect(invoice).to_not receive(:build_next_invoice)
          result = invoice.submit_for_settlement(gateway, "1234")
          expect(result).to be(transaction)
          expect(invoice.payment_method_id).to eq("1234")
          expect(invoice.transaction_id).to eq(transaction.id)
        end

        it "Will not create a new transaction if transaction ID provided" do
          plan_invoice = create(:invoice, plan_id: "567")
          expect(plan_invoice).to receive(:settle_invoice)
          expect(plan_invoice).to receive(:build_next_invoice)
          result = plan_invoice.submit_for_settlement(nil, nil, "1234")

          expect(plan_invoice.transaction_id).to eq("1234")
          expect(result).to be(nil)
        end

        it "Cannot be settled twice" do
          settled_invoice = create(:invoice, settled_at: Time.now)
          expect { settled_invoice.submit_for_settlement(gateway, "foo") }.to raise_error(Error::UnprocessableEntity)
        end

        it "Cannot process both payment method and transaction IDs" do
          expect { invoice.submit_for_settlement(gateway, "foo", "bar") }.to raise_error(Error::UnprocessableEntity)
        end

        it "Will build another invoice even if the first doesnt settle fully" do
          plan_invoice = create(:invoice, plan_id: "567")
          existing_invoice = create(:invoice, member: member, transaction_id: "different-transaction")
          expect(plan_invoice).to receive(:settle_invoice)
          expect(plan_invoice).to receive(:build_next_invoice)
          result = plan_invoice.submit_for_settlement(gateway, nil, transaction.id)

          expect(plan_invoice.transaction_id).to eq(transaction.id)
          expect(result).to be(nil)
        end
      end

      describe "build_next_invoice" do
        it "copys the calling invoice and resets with updated dates" do
          base_invoice = create(:invoice, settled_at: Time.now, refunded: true, due_date: Time.now, created_at: Time.now - 1.month)
          base_invoice.build_next_invoice
          new_invoice = Invoice.last
          expect(new_invoice.settled).to be_falsey
          expect(new_invoice.refunded).to be_falsey
          expect(new_invoice.past_due).to be_falsey
          expect(new_invoice.quantity).to eq(base_invoice.quantity)
        end

        it "does not carry a failed-payment flag from this cycle into the next" do
          # A transient failure on this cycle (later paid successfully) must
          # not cause a later, unrelated cancellation of next cycle's invoice
          # to be misreported as payment-related.
          base_invoice = create(:invoice, due_date: Time.now, settled_at: Time.now, last_failed_transaction_id: "txn-that-failed")
          base_invoice.build_next_invoice
          expect(Invoice.last.last_failed_transaction_id).to be_nil
        end
      end
    end

    describe "cancellation" do
      let(:member) { create(:member) }
      let(:rental) { create(:rental, member: member) }
      let(:paid_invoice) { create(:invoice, member: member, subscription_id: "foo", settled_at: Time.now) }
      let(:outstanding_rental_invoice) { create(:invoice, member: member, subscription_id: "rental", resource_class: "rental", resource_id: rental.id) }
      let(:outstanding_invoice) { create(:invoice, member: member, name: "outstanding", subscription_id: "foo") }

      describe "Cancel by subscription id" do
        it "deletes all outstanding invoices for the canceled subscription" do
          expect {
            Invoice.process_cancellation("foo").to change(Invoice, :count).by(-1)
          }
        end
      end

      describe "Cancel by invoice" do
        it "Notifies the member and management of the cancellation" do
          expect(SlackUser).to receive(:find_by).with({ member_id: member.id }).and_return(SlackUser.new())
          expect(::Service::SlackConnector).to receive(:send_slack_message).twice
          paid_invoice.send_cancellation_notification
        end

        it "Gracefully handles deleted rentals" do
          outstanding_rental_invoice
          rental.delete
          expect(SlackUser).to receive(:find_by).with({ member_id: member.id }).and_return(SlackUser.new())
          expect(::Service::SlackConnector).to receive(:send_slack_message).twice
          outstanding_rental_invoice.send_cancellation_notification
        end

        it "logs a plain cancellation and a neutral member message when no payment ever failed" do
          allow(SlackUser).to receive(:find_by).and_return(nil)
          expect(BillingMailer).to receive(:canceled_subscription)
            .with(member.email, "member", cancellation_reason: "")
            .and_return(double(deliver_later: true))

          expect(::Service::SlackConnector).to receive(:send_slack_message)
            .with(a_string_matching(/has been canceled\.\z/), ::Service::SlackConnector.members_relations_channel)

          expect { paid_invoice.send_cancellation_notification }.to change(AuditLog, :count).by(1)
          log = AuditLog.last
          expect(log.event_type).to eq("subscription_cancelled")
        end

        it "identifies an auto-cancellation from a failed payment in both the audit log and the member message" do
          allow(SlackUser).to receive(:find_by).and_return(nil)
          paid_invoice.update!(last_failed_transaction_id: "txn-failed-123")

          expect(BillingMailer).to receive(:canceled_subscription)
            .with(member.email, "member", cancellation_reason: " after repeated failed payment attempts")
            .and_return(double(deliver_later: true))

          expect(::Service::SlackConnector).to receive(:send_slack_message)
            .with(a_string_matching(/after repeated failed payment attempts\.\z/), ::Service::SlackConnector.members_relations_channel)

          expect { paid_invoice.send_cancellation_notification }.to change(AuditLog, :count).by(1)
          log = AuditLog.last
          expect(log.event_type).to eq("subscription_auto_cancelled_payment_failure")
          expect(log.slack_message).to include("txn-failed-123")
        end
      end
    end

    it "has getter method for past due" do
      future_invoice = create(:invoice, due_date: Time.now + 1.month)
      past_invoice = create(:invoice, due_date: Time.now - 1.month)
      expect(future_invoice.past_due).to be_falsey
      expect(past_invoice.past_due).to be_truthy
    end

    it "can fetch related resource" do
      member_invoice = create(:invoice, member: member, resource_id: member.id, resource_class: "member")
      rental_invoice = create(:invoice, member: member, resource_id: rental.id, resource_class: "rental")
      expect(member_invoice.resource).to eq(member)
      expect(rental_invoice.resource).to eq(rental)
    end

    it "programatically generates subscription IDs" do
      member_invoice = create(:invoice, member: member, resource_id: member.id, resource_class: "member")
      rental_invoice = create(:invoice, member: member, resource_id: rental.id, resource_class: "rental")
      expect(member_invoice.generate_subscription_id).to start_with("member_#{member.id}_")
      expect(rental_invoice.generate_subscription_id).to start_with("rental_#{rental.id}_")
    end

    it "can fetch current active invoice for a resource" do
      old_invoice = create(:settled_invoice, member: member, resource_id: rental.id, resource_class: "rental")
      old_invoice2 = create(:settled_invoice, member: member, resource_id: rental.id, resource_class: "rental")
      active_invoice = create(:invoice, member: member, resource_id: rental.id, resource_class: "rental")
      expect(Invoice.active_invoice_for_resource(rental.id)).to eq(active_invoice)
    end

    it "finds the oldest open invoice whose numeric amount matches" do
      newer_match = create(
        :invoice,
        member: member,
        resource_id: rental.id,
        resource_class: "rental",
        amount: 65.0,
        created_at: 1.day.ago
      )
      oldest_match = create(
        :invoice,
        member: member,
        resource_id: rental.id,
        resource_class: "rental",
        amount: 65.0,
        created_at: 2.days.ago
      )
      create(
        :invoice,
        member: member,
        resource_id: rental.id,
        resource_class: "rental",
        amount: 75.0,
        created_at: 3.days.ago
      )

      expect(Invoice.oldest_active_invoice_matching_amount(rental.id, BigDecimal("65.00"))).to eq(oldest_match)
      expect(Invoice.oldest_active_invoice_matching_amount(rental.id, 65)).not_to eq(newer_match)
    end

    it "finds matching invoices by member ownership regardless of resource" do
      rental_invoice = create(
        :invoice,
        member: member,
        resource_id: rental.id,
        resource_class: "rental",
        amount: 65.0
      )

      expect(Invoice.oldest_active_invoice_for_member_matching_amount(member.id, "65.00")).to eq(rental_invoice)
    end

    it "prioritizes subscription ID over plan and resource matches" do
      resource_invoice = create(
        :invoice,
        member: member,
        resource_id: rental.id,
        resource_class: "rental",
        amount: 65.0,
        created_at: 3.days.ago
      )
      subscription_invoice = create(
        :invoice,
        member: member,
        resource_id: rental.id,
        resource_class: "rental",
        subscription_id: "subscription-1",
        amount: 65.0,
        created_at: 1.day.ago
      )

      result = Invoice.oldest_active_subscription_invoice_matching_amount(
        subscription_id: "subscription-1",
        plan_id: nil,
        resource_id: rental.id,
        member_id: member.id,
        resource_class: "rental",
        amount: "65.00"
      )

      expect(result).to eq(subscription_invoice)
      expect(result).not_to eq(resource_invoice)
    end

    it "constrains plan fallback matches to the Braintree member" do
      other_member = create(:member)
      create(
        :invoice,
        member: other_member,
        resource_id: other_member.id,
        resource_class: "member",
        plan_id: "shared-plan",
        amount: 65.0,
        created_at: 2.days.ago
      )
      member_invoice = create(
        :invoice,
        member: member,
        resource_id: member.id,
        resource_class: "member",
        plan_id: "shared-plan",
        amount: 65.0,
        created_at: 1.day.ago
      )

      result = Invoice.oldest_active_subscription_invoice_matching_amount(
        subscription_id: "unknown-subscription",
        plan_id: "shared-plan",
        resource_id: member.id,
        member_id: member.id,
        resource_class: "member",
        amount: "65.00"
      )

      expect(result).to eq(member_invoice)
    end

    it "constrains plan fallback matches to the parsed subscription resource" do
      other_rental = create(:rental, member: member)
      create(
        :invoice,
        member: member,
        resource_id: other_rental.id,
        resource_class: "rental",
        plan_id: "shared-rental-plan",
        amount: 65.0,
        created_at: 2.days.ago
      )
      rental_invoice = create(
        :invoice,
        member: member,
        resource_id: rental.id,
        resource_class: "rental",
        plan_id: "shared-rental-plan",
        amount: 65.0,
        created_at: 1.day.ago
      )

      result = Invoice.oldest_active_subscription_invoice_matching_amount(
        subscription_id: "unknown-subscription",
        plan_id: "shared-rental-plan",
        resource_id: rental.id,
        member_id: member.id,
        resource_class: "rental",
        amount: "65.00"
      )

      expect(result).to eq(rental_invoice)
    end


    it "atomically claims an open invoice for one transaction" do
      open_invoice = create(
        :invoice,
        member: member,
        resource_id: rental.id,
        resource_class: "rental"
      )

      claimed_invoice = Invoice.claim_for_transaction(open_invoice.id, "transaction-1")

      expect(claimed_invoice.transaction_id).to eq("transaction-1")
      expect(claimed_invoice.locked).to be(true)
      expect(claimed_invoice.locked_at).to be_present
      expect(Invoice.claim_for_transaction(open_invoice.id, "transaction-2")).to be_nil
    end

    it "lets only one of two racing claims win the same invoice and transaction" do
      open_invoice = create(
        :invoice,
        member: member,
        resource_id: rental.id,
        resource_class: "rental"
      )

      results = Queue.new
      release = Queue.new
      threads = 2.times.map do
        Thread.new do
          release.pop
          results << Invoice.claim_for_transaction(open_invoice.id, "racing-transaction")
        end
      end
      2.times { release << true }
      threads.each(&:join)

      outcomes = Array.new(2) { results.pop }
      expect(outcomes.compact.length).to eq(1)
      open_invoice.reload
      expect(open_invoice.transaction_id).to eq("racing-transaction")
      expect(open_invoice.locked).to be(true)
    end

    it "does not claim a second invoice for the same transaction" do
      Invoice.collection.indexes.create_one(
        { transaction_id: 1 },
        unique: true,
        partial_filter_expression: { transaction_id: { '$type' => 'string' } }
      )
      first_invoice = create(
        :invoice,
        member: member,
        resource_id: rental.id,
        resource_class: "rental",
        created_at: 2.days.ago
      )
      second_invoice = create(
        :invoice,
        member: member,
        resource_id: rental.id,
        resource_class: "rental",
        created_at: 1.day.ago
      )

      expect(Invoice.claim_for_transaction(first_invoice.id, "shared-transaction")).to be_present
      expect(Invoice.claim_for_transaction(second_invoice.id, "shared-transaction")).to be_nil
      expect(second_invoice.reload.transaction_id).to be_nil
      expect(second_invoice.locked).to be(false)
    end

    it "reclaims an abandoned transaction lock after its lease expires" do
      abandoned_invoice = create(
        :invoice,
        member: member,
        resource_id: rental.id,
        resource_class: "rental",
        transaction_id: "transaction-1",
        locked: true,
        locked_at: 16.minutes.ago
      )

      reclaimed_invoice = Invoice.claim_for_transaction(abandoned_invoice.id, "transaction-1")

      expect(reclaimed_invoice).to be_present
      expect(reclaimed_invoice.locked).to be(true)
      expect(reclaimed_invoice.locked_at).to be > 1.minute.ago
    end
  end


  context "private methods" do
    let(:rental) { create(:rental) }

    it "sends an email when non-plan invoice created" do 
      allow_any_instance_of(Invoice).to receive(:send_rental_email)
      expect_any_instance_of(Invoice).to receive(:send_rental_email)
      create(:invoice, resource_class: "member", plan_id: nil)
    end 

    it "sends an email when a new rental subscription is craeted" do 
      allow_any_instance_of(Invoice).to receive(:send_rental_email)
      expect_any_instance_of(Invoice).to receive(:send_rental_email)
      create(:invoice, resource_id: rental.id, resource_class: "rental", subscription_id: nil)
    end

    it "normalizes due date to time zone if set with string" do
      time = Time.now.midnight
      time_as_string = time.strftime("%Y-%m-%d")

      time_invoice = create(:invoice, due_date: time)
      timestr_invoice = create(:invoice, due_date: time_as_string)

      expect(time_invoice.due_date).to eq(timestr_invoice.due_date)
    end

    describe "delay_invoice_operation" do
      let(:invoice) { create(:invoice) }

      it "validates resource exists" do
        no_resource = build(:invoice)
        no_resource.resource_id = nil
        expect(no_resource.resource).to be(nil)
        expect { no_resource.send(:execute_invoice_operation) }.to raise_error(Error::NotFound)
      end

      it "raises error if operation invalid" do
        no_operation = build(:invoice)
        no_operation.operation = nil
        expect(no_operation.operation).to be(nil)
        expect { no_operation.send(:execute_invoice_operation) }.to raise_error(Error::UnprocessableEntity)
      end

      it "delays invoice operation if delay callback exists" do
        allow(invoice).to receive_message_chain(:resource, :delay_invoice_operation).with(invoice.operation).and_return(true)
        expect(invoice).to receive_message_chain(:resource, :delay_invoice_operation).with(invoice.operation).and_return(true)
        expect(invoice).to receive(:enque_message).with("Delaying processing of invoice #{invoice.id}... Is member missing a key?")
        invoice.send(:execute_invoice_operation)
        expect(invoice.settled).to be_falsey
      end

      it "raises error if operation fails" do
        allow(invoice).to receive_message_chain(:resource, :delay_invoice_operation).with(invoice.operation).and_return(false)
        expect(invoice).to receive_message_chain(:resource, :execute_operation).with(invoice.operation, invoice).and_return(false)
        expect { invoice.send(:execute_invoice_operation) }.to raise_error(Error::UnprocessableEntity)
      end

      it "Settles the invoice if successful" do
        allow(invoice).to receive_message_chain(:resource, :delay_invoice_operation).with(invoice.operation).and_return(false)
        expect(invoice).to receive_message_chain(:resource, :delay_invoice_operation).with(invoice.operation).and_return(false)
        expect(invoice).to receive_message_chain(:resource, :execute_operation).with(invoice.operation, invoice).and_return(true)
        expect(invoice).to receive_message_chain(:resource, :send_renewal_slack_message)
        invoice.send(:execute_invoice_operation)
        expect(invoice.settled).to be_truthy
      end
    end
  end

  describe "#one_active_invoice_per_resource" do
    let(:member) { create(:member) }

    it "rejects a second active member invoice for the same resource without deleting the first" do
      first = create(
        :invoice,
        member: member,
        resource_class: "member",
        resource_id: member.id,
        description: "annual membership",
        amount: 65.5,
        created_at: Time.zone.local(2026, 1, 2)
      )

      second = build(:invoice, member: member, resource_class: "member", resource_id: member.id)
      expect(second).not_to be_valid
      expect(second.errors[:base]).to include(
        "Please pay outstanding annual membership invoice for $65.50 dated 01/02/2026"
      )

      # Non-destructive — the original invoice must still exist
      expect(Invoice.find(first.id)).to be_present
    end

    it "allows a member invoice to be created even if the member has an existing unpaid fee invoice" do
      # Fee invoices store resource_id == member_id with resource_class: "fee" —
      # this must not be mistaken for a duplicate membership invoice.
      create(:invoice, member: member, resource_class: "fee", resource_id: member.id)

      membership_invoice = build(:invoice, member: member, resource_class: "member", resource_id: member.id)
      expect(membership_invoice).to be_valid
    end

    it "allows a new member invoice once the previous one is settled" do
      settled = create(:settled_invoice, member: member, resource_class: "member", resource_id: member.id)

      new_invoice = build(:invoice, member: member, resource_class: "member", resource_id: member.id)
      expect(new_invoice).to be_valid
    end
  end
end
