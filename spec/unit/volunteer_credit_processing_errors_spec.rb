# Exercise the real credit helpers without Rails, MongoDB, or Slack.
require 'active_support/all'
require 'mongoid'
require_relative '../spec_helper'

RSpec.describe 'Volunteer credit follow-up error propagation' do
  let(:member) { double(id: BSON::ObjectId.new, subscription_id: 'subscription', active_membership_status?: true) }
  let(:failure) { RuntimeError.new('Processing unavailable') }

  before do
    stub_const('VolunteerCredit', Class.new)
    stub_const('FixTicketId', String)
    stub_const('Service::SlackConnector', Module.new do
      def self.logs_channel; end
      def self.treasurer_channel; end
      def self.send_slack_message(_message, _channel); end
    end)
    stub_const('Service::ErrorReporter', Module.new do
      def self.notify(_error); end
    end)
    load File.expand_path('../../app/models/volunteer_credit.rb', __dir__)
    allow(Mongo::Client).to receive(:new).and_raise('This unit spec must not connect to MongoDB')
    allow(Service::ErrorReporter).to receive(:notify)
    @credit = VolunteerCredit.new(member_id: member.id, description: 'Event attendance', status: 'approved')
    allow(@credit).to receive(:member).and_return(member)
  end

  context 'award notification' do
    before do
      # Failure computing the notification total is rescued by the real helper.
      allow(VolunteerCredit).to receive(:year_count_for).and_raise(failure)
    end

    it 'retains the existing rescued-error behavior by default' do
      expect { @credit.send(:notify_member_credit_awarded) }.not_to raise_error
      expect(Service::ErrorReporter).to have_received(:notify).with(failure)
    end

    it 'propagates the original error for event closure to report' do
      expect { @credit.send(:notify_member_credit_awarded, raise_errors: true) }
        .to raise_error { |error| expect(error).to equal(failure) }
      expect(Service::ErrorReporter).not_to have_received(:notify)
    end
  end

  context 'discount processing' do
    before do
      allow(VolunteerCredit).to receive(:discount_id).and_return('discount')
      stub_const('EarnedMembership', Class.new do
        def self.active; end
      end)
      active_memberships = double(where: double(exists?: false))
      allow(EarnedMembership).to receive(:active).and_return(active_memberships)
      allow(VolunteerCredit).to receive(:discount_eligible_year_count_for).and_return(8)
      allow(VolunteerCredit).to receive(:discounts_applied_this_year_for).and_return(0)
      allow(VolunteerCredit).to receive(:credits_per_discount).and_return(8)
      allow(VolunteerCredit).to receive(:max_discounts_per_year).and_return(2)
      allow(VolunteerCredit).to receive(:collection).and_return(double(find_one_and_update: { 'credit_value' => 8 }))
      stub_const('BraintreeService::VolunteerDiscount', Class.new do
        def self.apply(*_arguments); end
      end)
      allow(BraintreeService::VolunteerDiscount).to receive(:apply).and_raise(failure)
      allow(@credit).to receive(:notify_discount_error)
    end

    it 'retains the existing error reporting and discount notice by default' do
      expect { @credit.send(:check_discount_threshold!) }.not_to raise_error
      expect(Service::ErrorReporter).to have_received(:notify).with(failure)
      expect(@credit).to have_received(:notify_discount_error).with(member, failure)
    end

    it 'propagates the original error without reporting or notifying again' do
      expect { @credit.send(:check_discount_threshold!, raise_errors: true) }
        .to raise_error { |error| expect(error).to equal(failure) }
      expect(Service::ErrorReporter).not_to have_received(:notify)
      expect(@credit).not_to have_received(:notify_discount_error)
    end

    context 'event closure owns reporting' do
      before do
        stub_const('SanitizesUserInput', Module.new)
        stub_const('VolunteerEvent', Class.new)
        load File.expand_path('../../app/models/volunteer_event.rb', __dir__)
        stub_const('Member', Class.new do
          def self.find(_id); end
        end)
        allow(Member).to receive(:find).and_return(member)
        allow(VolunteerCredit).to receive(:create!).and_return(@credit)
        allow(@credit).to receive(:notify_member_credit_awarded)
        allow(@credit).to receive(:notify_discount_error).and_call_original
        stub_const('Service::EmailTemplate', Module.new do
          def self.common_variables(_member); end
          def self.render(*_arguments, **_options); end
        end)
        allow(Service::EmailTemplate).to receive(:common_variables).and_return({})
        allow(Service::EmailTemplate).to receive(:render) { |kind, *_arguments| kind.to_s }
        stub_const('SlackUser', Class.new do
          def self.find_by(**_attributes); end
        end)
        allow(SlackUser).to receive(:find_by).and_return(nil)
        allow(Service::SlackConnector).to receive(:logs_channel).and_return('CLOGS')
        allow(Service::SlackConnector).to receive(:treasurer_channel).and_return('CTREASURER')
        allow(Service::SlackConnector).to receive(:send_slack_message) do |message, _channel|
          raise failure if %w[volunteer_discount_applied_admin volunteer_discount_no_subscription].include?(message)
          { 'ok' => true }
        end
        @event = VolunteerEvent.new(title: 'Cleanup', event_number: 3, event_date: Date.current - 6,
          attendee_ids: [member.id])
        allow(@event).to receive(:reload).and_return(@event)
        stub_const('Service::VolunteerApprovalReminder', Module.new do
          def self.outcome_attributes(_record, outcome:, closed_at:); end
          def self.transition_with_outcome!(_record, _attributes, notification:); end
          def self.record_outcome!(_record, _notification, expected_status:); end
          def self.sync_closed!(_record); end
        end)
        allow(Service::VolunteerApprovalReminder).to receive(:outcome_attributes) do |_record, outcome:, closed_at:|
          { approval_notification: { 'outcome' => outcome, 'closed_at' => closed_at } }
        end
        allow(Service::VolunteerApprovalReminder).to receive(:transition_with_outcome!) do |record, attributes, notification:|
          record.assign_attributes(attributes.merge(approval_notification: notification))
        end
        allow(Service::VolunteerApprovalReminder).to receive(:record_outcome!) do |record, notification, **_options|
          record.approval_notification = notification
        end
        allow(Service::VolunteerApprovalReminder).to receive(:sync_closed!)
      end

      %i[payment applied_notice no_subscription_notice].each do |failed_operation|
        it "reports #{failed_operation} failure once and emits one discount error notice" do
          if failed_operation != :payment
            result = failed_operation == :applied_notice ? { amount: 10, cycles_added: 1 } : :no_subscription
            allow(BraintreeService::VolunteerDiscount).to receive(:apply).and_return(result)
          end

          @event.close!(double(id: BSON::ObjectId.new, fullname: 'Reviewer'))

          expect(Service::ErrorReporter).to have_received(:notify).with(failure).once
          expect(@credit).to have_received(:notify_discount_error).with(member, failure).once
          expect(Service::SlackConnector).to have_received(:send_slack_message).with('volunteer_discount_error', 'CLOGS').once
          expect(@event.approval_notification['outcome']).to include('follow-up processing failed', member.id.to_s)
        end
      end

      %i[dm template].each do |failed_operation|
        it "still applies the threshold discount after the award #{failed_operation} fails" do
          allow(@credit).to receive(:notify_member_credit_awarded).and_call_original
          allow(VolunteerCredit).to receive(:year_count_for).and_return(8)
          allow(SlackUser).to receive(:find_by).and_return(double(slack_id: 'UMEMBER'))
          allow(BraintreeService::VolunteerDiscount).to receive(:apply)
            .and_return(amount: 10, cycles_added: 1, total_cycles: 1, description: 'Volunteer')
          allow(Service::SlackConnector).to receive(:send_slack_message) do |message, _channel|
            raise failure if failed_operation == :dm && message == 'volunteer_credit_awarded'
            { 'ok' => true }
          end
          if failed_operation == :template
            allow(Service::EmailTemplate).to receive(:render) do |kind, *_arguments|
              raise failure if kind.to_s == 'volunteer_credit_awarded'
              kind.to_s
            end
          end

          @event.close!(double(id: BSON::ObjectId.new, fullname: 'Reviewer'))

          expect(VolunteerCredit).to have_received(:create!).once
          expect(BraintreeService::VolunteerDiscount).to have_received(:apply).with(member, 'discount', 1).once
          expect(Service::ErrorReporter).to have_received(:notify).with(failure).once
          expect(@credit).not_to have_received(:notify_discount_error)
          expect(@event.approval_notification['outcome']).to include('failed for 1 attendee', 'award notification')
          expect(@event.approval_notification['outcome']).not_to include('membership discount processing')
        end
      end
    end
  end

  context 'discount notices' do
    before do
      stub_const('Service::EmailTemplate', Module.new do
        def self.common_variables(_member); end
      end)
      allow(Service::EmailTemplate).to receive(:common_variables).and_raise(failure)
      stub_const('SlackUser', Class.new do
        def self.find_by(**_attributes); end
      end)
      allow(SlackUser).to receive(:find_by).and_return(nil)
      allow(@credit).to receive(:notify_discount_error)
    end

    { notify_no_subscription: [], notify_discount_applied: [{ amount: 10, cycles_added: 1 }] }.each do |method, arguments|
      it "keeps #{method}'s default handling and propagates the error when requested" do
        expect { @credit.send(method, member, *arguments) }.not_to raise_error
        expect { @credit.send(method, member, *arguments, raise_errors: true) }
          .to raise_error { |error| expect(error).to equal(failure) }
        expect(Service::ErrorReporter).to have_received(:notify).with(failure).once
      end
    end
  end
end
