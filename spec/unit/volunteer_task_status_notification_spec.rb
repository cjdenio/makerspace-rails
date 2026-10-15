# Load the complete Mongoid model and real reminder service without booting Rails:
# ruby -r rspec/autorun spec/unit/volunteer_task_status_notification_spec.rb
require 'active_support/all'
require 'active_support/testing/time_helpers'
require 'mongoid'
require_relative '../spec_helper'
require_relative '../../app/services/service/volunteer_approval_reminder'
require_relative '../../lib/error/service_unavailable'

RSpec.describe 'Volunteer lifecycle and status notification integration' do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.utc(2026, 10, 4, 16) }
  let(:actor) { double(id: BSON::ObjectId.new, fullname: 'Sam Reviewer') }
  let(:verifier) { double(id: BSON::ObjectId.new, fullname: 'Sam Reviewer') }
  let(:receipt) do
    {
      'ts' => '123.456', 'channel' => 'CORIGINAL', 'destination_mode' => 'production',
      'started_at' => now - 6.days, 'subject' => 'Task #17 for Pat Member', 'finalized' => true
    }
  end
  let(:task) do
    VolunteerTask.new(
      title: 'Sort lumber', description: 'Label the bins', task_number: 17,
      status: 'pending', completed_at: now - 6.days, approval_notification: receipt.deep_dup
    )
  end

  around { |example| Time.use_zone('America/New_York') { travel_to(now) { example.run } } }

  before do
    # These concerns/types have separate integration coverage. The tested task
    # methods come from the full model source, never extracted or reimplemented.
    stub_const('FixTicketBounty', Module.new)
    stub_const('SanitizesUserInput', Module.new)
    stub_const('FixTicketId', String)
    stub_const('VolunteerEvent', Class.new)
    stub_const('VolunteerTask', Class.new)
    stub_const('Error::Forbidden', Class.new(StandardError)) unless defined?(Error::Forbidden)
    stub_const('Service::SlackConnector', Module.new do
      def self.message_destination_mode; end
      def self.send_slack_message(_text, _channel); end
      def self.update_slack_message(_channel, _ts, _text, resolved_channel: false); end
    end)
    stub_const('Service::ErrorReporter', Module.new do
      def self.notify(_error); end
    end)
    stub_const('SystemConfig', Class.new do
      def self.get(_key); end
    end)
    stub_const('Member', Class.new do
      def self.find(_id); end
    end)
    stub_const('VolunteerCredit', Class.new do
      def self.create!(**_attributes); end
    end)
    stub_const('VolunteerApproverNotification', Class.new do
      def self.preserve_event_receipts!(_record, event_date:); end
    end)
    allow(SystemConfig).to receive(:get).and_return('2.0')
    allow(Member).to receive(:find).and_return(double(fullname: 'Pat Member'))
    allow(VolunteerCredit).to receive(:create!)
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('production')
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::SlackConnector).to receive(:update_slack_message).and_return('ok' => true)
    allow(Service::ErrorReporter).to receive(:notify)
    allow(VolunteerApproverNotification).to receive(:preserve_event_receipts!)
    load File.expand_path('../../app/models/volunteer_task.rb', __dir__)
    load File.expand_path('../../app/models/volunteer_event.rb', __dir__)

    stub_const('ApplicationJob', Class.new do
      def self.queue_as(_queue); end
    end)
    stub_const('VolunteerEventReminderJob', Class.new(ApplicationJob))
    load File.expand_path('../../app/jobs/volunteer_event_reminder_job.rb', __dir__)

    # Criteria are inspected without execution; fail before any accidental socket.
    allow(Mongo::Client).to receive(:new).and_raise('This unit spec must not connect to MongoDB')
    # Only the persistence boundaries are replaced. Mongoid fields, validation,
    # task lifecycle helpers, raw receipt selectors, and Slack text remain real.
    @persisted = task.attributes.deep_dup
    @raw_updates = []
    @lifecycle_snapshots = []
    allow(task).to receive(:reload) do
      task.assign_attributes(@persisted.deep_dup)
      task
    end
    allow(task).to receive(:update!) do |attributes|
      persist_lifecycle_update(attributes)
    end
    collection = double('In-memory volunteer collection')
    allow(task.class).to receive(:collection).and_return(collection)
    allow(collection).to receive(:find) do |selector|
      query = double('Atomic receipt update')
      allow(query).to receive(:find_one_and_update) do |update, **_options|
        @raw_updates << [selector.deep_dup, update.deep_dup]
        if matches?(@persisted, selector)
          apply_update!(@persisted, update)
          @lifecycle_snapshots << @persisted.deep_dup if update.fetch('$set', {}).key?('status')
          @persisted.deep_dup
        end
      end
      query
    end
  end

  def value_at(document, path)
    path.split('.').reduce(document) do |value, name|
      value.is_a?(Array) ? value[name.to_i] : value&.[](name)
    end
  end

  def matches?(document, selector)
    selector.all? do |path, expected|
      if path == '$or'
        expected.any? { |branch| matches?(document, branch) }
      else
        actual = value_at(document, path)
        if expected.is_a?(Hash) && expected.key?('$not')
          Array(actual).none? { |saved| matches?(saved, expected.fetch('$not').fetch('$elemMatch')) }
        elsif expected.is_a?(Hash) && expected.key?('$elemMatch')
          Array(actual).any? { |saved| matches?(saved, expected.fetch('$elemMatch')) }
        elsif expected.is_a?(Hash) && expected.key?('$lt')
          actual && actual < expected.fetch('$lt')
        else
          actual == expected
        end
      end
    end
  end

  def apply_update!(document, update)
    update.fetch('$set', {}).each do |path, value|
      names = path.split('.')
      container = names.length == 1 ? document : value_at(document, names.take(names.length - 1).join('.'))
      container.is_a?(Array) ? container[names.last.to_i] = value : container[names.last] = value
    end
    update.fetch('$push', {}).each do |path, value|
      values = value.is_a?(Hash) && value.key?('$each') ? value.fetch('$each') : [value]
      value_at(document, path).concat(values)
    end
  end

  def persisted_model_with_real_callbacks
    loaded = Mongoid::Factory.from_db(task.class, @persisted.deep_dup)
    collection = double('MongoDB event write boundary')
    @model_commands = []
    allow(loaded).to receive(:collection).and_return(collection)
    allow(task.class).to receive(:collection).and_return(collection)
    allow(collection).to receive(:find) do |selector|
      view = double('MongoDB event collection view')
      allow(view).to receive(:read).and_return(view)
      allow(view).to receive(:first) { matches?(@persisted, selector) ? @persisted.deep_dup : nil }
      allow(view).to receive(:delete_one) do |**_options|
        @deletion_snapshot = @persisted.deep_dup
        double(deleted_count: 1)
      end
      allow(view).to receive(:update_one) do |update, **_options|
        expect(matches?(@persisted, selector)).to be(true)
        apply_update!(@persisted, update)
        @model_commands << [selector.deep_dup, update.deep_dup, @persisted.deep_dup]
        double(matched_count: 1, modified_count: 1)
      end
      allow(view).to receive(:find_one_and_update) do |update, **_options|
        @raw_updates << [selector.deep_dup, update.deep_dup]
        if matches?(@persisted, selector)
          apply_update!(@persisted, update)
          if update.fetch('$set', {}).key?('event_date')
            @model_commands << [selector.deep_dup, update.deep_dup, @persisted.deep_dup]
          end
          @persisted.deep_dup
        end
      end
      view
    end
    loaded
  end

  def persist_lifecycle_update(attributes)
    task.assign_attributes(attributes)
    raise Mongoid::Errors::Validations.new(task) unless task.valid?

    attributes.each_key { |name| @persisted[name.to_s] = task.attributes[name.to_s].deep_dup }
    apply_update!(@persisted, '$set' => task.delayed_atomic_sets.deep_dup)
    @lifecycle_snapshots << @persisted.deep_dup if attributes.key?(:status) || attributes.key?('status')
    task.assign_attributes(@persisted.deep_dup)
    task
  end

  def edit_status(new_status, reviewer: actor)
    notification = task.update_with_review_outcome!({ status: new_status }, actor: reviewer)
    task.close_pending_review_notification!(notification)
    task.reload.approval_notification
  end

  def expect_durable_closure(status, outcome: nil)
    saved = @lifecycle_snapshots.find { |snapshot| snapshot.fetch('status') == status }
    expect(saved).to be_present
    expect(saved.fetch('approval_notification')).to include(
      'ts' => receipt['ts'], 'channel' => receipt['channel'], 'closed_at' => now, 'finalized' => false
    )
    expect(saved.fetch('approval_notification')['outcome']).to be_present
    expect(saved.fetch('approval_notification')['outcome']).to eq(outcome) if outcome
    criteria = VolunteerEventReminderJob.new.send(:retry_notifications, task.class)
    expect(matches?(saved, criteria.selector)).to be(true)
    saved.fetch('approval_notification')
  end

  it 'combines the actual Mongoid lifecycle and dotted closure changes into one database update' do
    loaded = Mongoid::Factory.from_db(VolunteerTask, @persisted.deep_dup)
    expect(loaded).to be_persisted
    expect(loaded).not_to be_changed
    commands = []
    collection = double('MongoDB write boundary')
    allow(loaded).to receive(:collection).and_return(collection)
    allow(collection).to receive(:find) do |selector|
      view = double('MongoDB collection view')
      allow(view).to receive(:update_one) do |update, **_options|
        commands << [selector.deep_dup, update.deep_dup]
        double(matched_count: 1, modified_count: 1)
      end
      view
    end
    notification = loaded.pending_review_outcome_for_status('cancelled')

    Service::VolunteerApprovalReminder.transition_with_outcome!(loaded, { status: 'cancelled' }, notification: notification)

    expect(commands.length).to eq(1)
    selector, update = commands.fetch(0)
    expect(selector).to include('_id' => loaded.id)
    expect(update.fetch('$set')).to include(
      'status' => 'cancelled',
      'approval_notification.started_at' => now - 6.days,
      'approval_notification.closed_at' => now,
      'approval_notification.outcome' => 'Task cancelled',
      'approval_notification.finalized' => false
    )
    expect(update.fetch('$set')).not_to include('approval_notification', 'approval_notification.ts', 'approval_notification.channel')
    expect(loaded.delayed_atomic_sets).to be_empty
  end

  it 'records an actionable credit failure rather than an approved outcome when creation raises' do
    creation_error = RuntimeError.new('Credit storage unavailable')
    allow(VolunteerCredit).to receive(:create!).and_raise(creation_error)
    allow(task).to receive(:notify_task_verified)

    expect { task.complete!(verifier) }.to raise_error { |error| expect(error).to equal(creation_error) }

    expect(task.reload.status).to eq('completed')
    expect_durable_closure('completed')
    expect(task.approval_notification).to include(
      'closed_at' => now, 'finalized' => true,
      'outcome' => 'Credit award failed during approval by Sam Reviewer; verify whether a credit was saved and correct the award manually'
    )
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CORIGINAL', '123.456', a_string_including('⚠️', 'Credit award failed', 'correct the award manually', '6 days'),
      resolved_channel: true
    ).once
    expect(task).not_to have_received(:notify_task_verified)
    expect { task.complete!(verifier) }.to raise_error(Error::Forbidden)
    expect(VolunteerCredit).to have_received(:create!).once
  end

  it 'keeps a failed credit warning retryable by the job when its Slack update fails' do
    allow(VolunteerCredit).to receive(:create!).and_raise('Credit storage unavailable')
    allow(Service::SlackConnector).to receive(:update_slack_message).and_raise('Slack unavailable')

    expect { task.complete!(verifier) }.to raise_error(RuntimeError, 'Credit storage unavailable')

    criteria = VolunteerEventReminderJob.new.send(:retry_notifications, VolunteerTask)
    expect(matches?(@persisted, criteria.selector)).to be(true)
    expect(task.reload.approval_notification).to include('closed_at' => now, 'finalized' => false)

    allow(Service::SlackConnector).to receive(:update_slack_message).and_return('ok' => true)
    Service::VolunteerApprovalReminder.sync_closed!(task)

    expect(task.reload.approval_notification['finalized']).to be(true)
    expect(matches?(@persisted, criteria.selector)).to be(false)
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CORIGINAL', '123.456', a_string_including('⚠️', 'Credit award failed', '6 days'), resolved_channel: true
    ).twice
    expect(VolunteerCredit).to have_received(:create!).once
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'preserves the credit creation error when saving failure metadata also fails' do
    creation_error = RuntimeError.new('Credit storage unavailable')
    allow(VolunteerCredit).to receive(:create!).and_raise(creation_error)
    allow(Service::VolunteerApprovalReminder).to receive(:write_notification).and_raise('Metadata storage unavailable')

    expect { task.complete!(verifier) }.to raise_error { |error| expect(error).to equal(creation_error) }

    expect_durable_closure('completed')
    expect(task.reload.approval_notification).to include('closed_at' => now, 'finalized' => false)
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
    expect(Service::ErrorReporter).to have_received(:notify).with(an_instance_of(RuntimeError)).once
  end

  it 'keeps a completed task actionable when credit succeeds but recording the approved outcome fails' do
    credit = double(notify_member_credit_awarded: nil, check_discount_threshold!: nil)
    allow(VolunteerCredit).to receive(:create!).and_return(credit)
    allow(task).to receive(:notify_task_verified)
    allow(Service::VolunteerApprovalReminder).to receive(:write_notification).and_raise('Metadata storage unavailable')

    expect { task.complete!(verifier) }.to raise_error(RuntimeError, 'Metadata storage unavailable')

    initial = expect_durable_closure('completed')
    expect(initial['outcome']).not_to eq('Approved by Sam Reviewer')
    expect(task.reload.status).to eq('completed')
    expect(task.approval_notification).to eq(initial)
    expect(VolunteerCredit).to have_received(:create!).once
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)

    allow(Service::VolunteerApprovalReminder).to receive(:write_notification).and_call_original
    Service::VolunteerApprovalReminder.sync_closed!(task)

    expect(task.reload.approval_notification['finalized']).to be(true)
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CORIGINAL', '123.456', a_string_including(initial.fetch('outcome'), '6 days'), resolved_channel: true
    ).once
    expect(VolunteerCredit).to have_received(:create!).once
  end

  it 'retains the approved outcome when discount processing fails after credit creation succeeds' do
    credit = double(notify_member_credit_awarded: nil, check_discount_threshold!: nil)
    allow(VolunteerCredit).to receive(:create!).and_return(credit)
    allow(credit).to receive(:check_discount_threshold!).and_raise('Discount processing unavailable')

    expect { task.complete!(verifier) }.to raise_error(RuntimeError, 'Discount processing unavailable')

    expect(task.reload.approval_notification).to include(
      'outcome' => 'Approved by Sam Reviewer', 'finalized' => true
    )
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CORIGINAL', '123.456', a_string_including('✅', 'Approved by Sam Reviewer', '6 days'), resolved_channel: true
    ).once
  end

  [false, true].each do |child|
    it "saves #{child ? 'child' : 'ordinary'} denial metadata in the same write that ends pending review" do
      claimant_id = BSON::ObjectId.new
      task.update!(claimed_by_id: claimant_id, parent_task_id: child ? BSON::ObjectId.new : nil)
      allow(Service::VolunteerApprovalReminder).to receive(:record_outcome!).and_raise('Later metadata write unavailable')

      expect { task.reject_pending!(verifier, 'Incomplete cleanup', notify: false) }.not_to raise_error

      status = child ? 'denied' : 'available'
      expect_durable_closure(status, outcome: 'Denied by Sam Reviewer. Reason: Incomplete cleanup')
      expect(task.reload.status).to eq(status)
      expect(task.approval_notification['finalized']).to be(false)
      expect(task.claimed_by_id).to eq(child ? claimant_id : nil)
      expect(task.completed_at).to eq(child ? now - 6.days : nil)
      expect(Service::VolunteerApprovalReminder).not_to have_received(:record_outcome!)
      expect(VolunteerCredit).not_to have_received(:create!)

      Service::VolunteerApprovalReminder.sync_closed!(task)
      expect(task.reload.approval_notification['finalized']).to be(true)
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        'CORIGINAL', '123.456', a_string_including('Denied by Sam Reviewer', 'Incomplete cleanup', '6 days'),
        resolved_channel: true
      ).once
    end
  end

  it 'preserves a reminder timestamp registered after the closure snapshot was created' do
    task.update!(approval_notification: receipt.except('ts', 'channel', 'destination_mode'))
    allow(task).to receive(:update!) do |attributes|
      @persisted.fetch('approval_notification').merge!(
        'ts' => 'CONCURRENT', 'channel' => 'CLATE', 'destination_mode' => 'production'
      )
      persist_lifecycle_update(attributes)
    end

    task.cancel!

    saved = @lifecycle_snapshots.find { |snapshot| snapshot.fetch('status') == 'cancelled' }
    expect(saved.fetch('approval_notification')).to include(
      'ts' => 'CONCURRENT', 'channel' => 'CLATE', 'outcome' => 'Task cancelled', 'closed_at' => now,
      'finalized' => false
    )
    expect(task.reload.approval_notification).to include('ts' => 'CONCURRENT', 'channel' => 'CLATE', 'finalized' => true)
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CLATE', 'CONCURRENT', a_string_including('Task cancelled', '6 days'), resolved_channel: true
    ).once
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'promotes an approval snapshot when a reminder generation is registered during the lifecycle write' do
    task.update!(approval_notification: {})
    credit = double(notify_member_credit_awarded: nil, check_discount_threshold!: nil)
    allow(VolunteerCredit).to receive(:create!).and_return(credit)
    allow(task).to receive(:notify_task_verified)
    allow(task).to receive(:update!) do |attributes|
      @persisted['approval_notification'] = receipt.merge('generation_id' => 'CONCURRENT-GENERATION')
      persist_lifecycle_update(attributes)
    end

    task.complete!(verifier)

    expect(task.reload.status).to eq('completed')
    expect(task.approval_notification).to include(
      'generation_id' => 'CONCURRENT-GENERATION', 'ts' => receipt.fetch('ts'),
      'outcome' => 'Approved by Sam Reviewer', 'closed_at' => now, 'finalized' => true
    )
    expect(task.approval_notification_history).to be_empty
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CORIGINAL', '123.456', a_string_including('Approved by Sam Reviewer', '6 days'), resolved_channel: true
    ).once
    expect(VolunteerCredit).to have_received(:create!).once
  end

  it 'closes cancellation even when the pending receipt was already marked finalized' do
    task.cancel!

    expect(task.reload.status).to eq('cancelled')
    expect_durable_closure('cancelled', outcome: 'Task cancelled')
    expect(task.approval_notification).to include(
      'ts' => receipt['ts'], 'channel' => receipt['channel'], 'outcome' => 'Task cancelled',
      'closed_at' => now, 'started_at' => now - 6.days, 'finalized' => true
    )
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CORIGINAL', '123.456', a_string_including('Task cancelled', 'Review closed after 6 days.'),
      resolved_channel: true
    ).once
    expect(VolunteerCredit).not_to have_received(:create!)
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'makes a failed cancellation final update selectable by the real job and retries in place' do
    allow(Service::SlackConnector).to receive(:update_slack_message).and_raise('Slack unavailable')

    expect { task.cancel! }.not_to raise_error
    expect(task.reload.status).to eq('cancelled')
    expect(task.approval_notification).to include('closed_at' => now, 'finalized' => false)
    criteria = VolunteerEventReminderJob.new.send(:retry_notifications, VolunteerTask)
    expect(matches?(@persisted, criteria.selector)).to be(true)
    expect(criteria.selector.fetch('$or')).to include('approval_notification.finalized' => false)

    allow(Service::SlackConnector).to receive(:update_slack_message).and_return('ok' => true)
    Service::VolunteerApprovalReminder.remind!(task, now: now + 1.day)

    expect(task.reload.approval_notification).to include('closed_at' => now, 'finalized' => true)
    expect(matches?(@persisted, criteria.selector)).to be(false)
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CORIGINAL', '123.456', a_string_including('Task cancelled', 'Review closed after 6 days.'),
      resolved_channel: true
    ).twice
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    expect(Service::ErrorReporter).to have_received(:notify).once
  end

  {
    'completed' => 'Task marked completed by Sam Reviewer through a status edit; no credits were issued by this edit',
    'denied' => 'Denied by Sam Reviewer through a task status edit',
    'cancelled' => 'Task cancelled by Sam Reviewer',
    'claimed' => 'Pending review ended by Sam Reviewer; task status changed to claimed',
    'available' => 'Pending review ended by Sam Reviewer; task status changed to available'
  }.each do |status, outcome|
    it "describes a generic edit to #{status} accurately without awarding credits" do
      notification = edit_status(status)

      expect(task.status).to eq(status)
      expect_durable_closure(status, outcome: outcome)
      expect(notification).to include('outcome' => outcome, 'closed_at' => now, 'finalized' => true)
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        'CORIGINAL', '123.456', a_string_including(outcome, 'Review closed after 6 days.'),
        resolved_channel: true
      ).once
      expect(VolunteerCredit).not_to have_received(:create!)
    end
  end

  it 'does not rewrite an already closed review when the completed task is later cancelled' do
    approved = receipt.merge('closed_at' => now - 1.day, 'outcome' => 'Approved earlier')
    task.update!(status: 'completed', approval_notification: approved)

    task.cancel!

    expect(task.reload.status).to eq('cancelled')
    expect(task.approval_notification).to eq(approved)
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end

  it 'stores a closed snapshot without posting when cancellation preceded the initial reminder' do
    task.update!(approval_notification: {})

    task.cancel!

    expect(task.reload.approval_notification).to include(
      'started_at' => now - 6.days, 'closed_at' => now, 'outcome' => 'Task cancelled', 'finalized' => true
    )
    expect(task.approval_notification['ts']).to be_nil
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end

  it 'leaves the receipt open for blank or unchanged status and title-only edits' do
    [nil, '', ' ', 'pending'].each do |status|
      expect(task.pending_review_outcome_for_status(status, actor: actor)).to eq({})
    end
    task.update!(title: 'Sort plywood')
    task.close_pending_review_notification!({})

    expect(task.reload.approval_notification).to eq(receipt)
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end

  it 'does not create review metadata when cancelling an unfinished claim with no receipt' do
    task.update!(status: 'claimed', completed_at: nil, approval_notification: {})

    task.cancel!

    expect(task.reload.status).to eq('cancelled')
    expect(task.approval_notification).to eq({})
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end

  it 'retains a pending receipt when a generic status edit fails Mongoid validation' do
    expect { edit_status('invalid-status') }.to raise_error(Mongoid::Errors::Validations)

    expect(task.reload.status).to eq('pending')
    expect(task.approval_notification).to eq(receipt)
    expect(task.delayed_atomic_sets).to be_empty
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end

  it 'finalizes an outstanding receipt even if a previous edit already withdrew pending status' do
    task.update!(status: 'claimed')

    notification = edit_status('available', reviewer: nil)

    expect(notification).to include(
      'outcome' => 'Pending review ended; task status changed to available', 'closed_at' => now, 'finalized' => true
    )
    expect(Service::SlackConnector).to have_received(:update_slack_message).once
  end

  context 'when closing an event' do
    let(:receipt) do
      super().merge('subject' => 'Event E8 with 1 checked-in attendee')
    end
    let(:attendee_id) { BSON::ObjectId.new }
    let(:task) do
      VolunteerEvent.new(
        title: 'Community cleanup', event_number: 8, event_date: now.in_time_zone.to_date - 6,
        attendee_ids: [attendee_id], approval_notification: receipt.deep_dup
      )
    end

    before do
      allow(Member).to receive(:find).with(attendee_id).and_return(double(active_membership_status?: true))
    end

    it 'persists the event outcome before issuing attendance credits and can retry the final Slack message' do
      credit = double(notify_member_credit_awarded: nil, check_discount_threshold!: nil)
      allow(VolunteerCredit).to receive(:create!) do
        expect(expect_durable_closure('closed')['outcome']).to start_with('Credit award not confirmed')
        credit
      end
      allow(Service::SlackConnector).to receive(:update_slack_message).and_raise('Slack unavailable')

      expect { task.close!(verifier) }.not_to raise_error

      expect(task.reload.status).to eq('closed')
      expect(task.closed_at).to eq(now)
      expect(task.approval_notification).to include('closed_at' => now, 'finalized' => false)
      expect(expect_durable_closure('closed')['outcome']).to start_with('Credit award not confirmed')
      expect(task.approval_notification['outcome']).to eq('Event closed by Sam Reviewer')
      expect(VolunteerCredit).to have_received(:create!).once

      allow(Service::SlackConnector).to receive(:update_slack_message).and_return('ok' => true)
      Service::VolunteerApprovalReminder.sync_closed!(task)
      expect(task.reload.approval_notification['finalized']).to be(true)
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        'CORIGINAL', '123.456', a_string_including('Event closed by Sam Reviewer', '6 days'), resolved_channel: true
      ).twice
      expect(VolunteerCredit).to have_received(:create!).once
    end

    it 'reports a partial creation failure while still awarding other attendees and retries the warning' do
      other_id = BSON::ObjectId.new
      task.attendee_ids << other_id
      @persisted['attendee_ids'] = task.attendee_ids.deep_dup
      allow(Member).to receive(:find).with(other_id).and_return(double(active_membership_status?: true))
      credit = double(notify_member_credit_awarded: nil, check_discount_threshold!: nil)
      allow(VolunteerCredit).to receive(:create!) do |**attributes|
        raise 'Credit storage unavailable' if attributes[:member_id] == attendee_id
        credit
      end
      allow(Service::SlackConnector).to receive(:update_slack_message).and_raise('Slack unavailable')

      task.close!(verifier)

      expect(task.reload.status).to eq('closed')
      expect(task.approval_notification).to include('finalized' => false, 'closed_at' => now)
      expect(task.approval_notification['outcome']).to include('failed for 1 attendee', attendee_id.to_s, 'credit creation')
      expect(VolunteerCredit).to have_received(:create!).with(hash_including(member_id: other_id)).once
      expect(Service::ErrorReporter).to have_received(:notify).with(have_attributes(message: 'Credit storage unavailable')).once
      allow(Service::SlackConnector).to receive(:update_slack_message).and_return('ok' => true)
      Service::VolunteerApprovalReminder.sync_closed!(task)
      expect(task.reload.approval_notification['finalized']).to be(true)
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        'CORIGINAL', '123.456', a_string_including('⚠️', attendee_id.to_s, '6 days', 'duplicate credits'), resolved_channel: true
      ).twice
      expect(VolunteerCredit).to have_received(:create!).twice
    end

    { notify_member_credit_awarded: 'award notification', check_discount_threshold!: 'membership discount processing' }.each do |method, stage|
      it "records a warning when #{stage} fails after the credit was created" do
        credit = double(notify_member_credit_awarded: nil, check_discount_threshold!: nil, notify_discount_error: nil)
        allow(credit).to receive(method).and_raise('Follow-up unavailable')
        allow(VolunteerCredit).to receive(:create!).and_return(credit)

        task.close!(verifier)

        expect(task.reload.approval_notification['outcome']).to include('Credit award failed or follow-up processing failed',
          attendee_id.to_s, stage)
        expect(task.approval_notification['finalized']).to be(true)
        expect(Service::SlackConnector).to have_received(:update_slack_message).with(
          'CORIGINAL', '123.456', a_string_including('⚠️', stage, '6 days'), resolved_channel: true
        )
        expect(VolunteerCredit).to have_received(:create!).once
        expect(credit).to have_received(:check_discount_threshold!).with(raise_errors: true).once
        expect(Service::ErrorReporter).to have_received(:notify).with(have_attributes(message: 'Follow-up unavailable')).once
        if method == :check_discount_threshold!
          expect(credit).to have_received(:notify_discount_error).with(anything, have_attributes(message: 'Follow-up unavailable')).once
        else
          expect(credit).not_to have_received(:notify_discount_error)
        end
      end
    end

    it 'records both follow-up failures for one attendee without duplicating their credit' do
      award_error = RuntimeError.new('Award DM unavailable')
      discount_error = RuntimeError.new('Billing unavailable')
      credit = double(notify_member_credit_awarded: nil, check_discount_threshold!: nil, notify_discount_error: nil)
      allow(credit).to receive(:notify_member_credit_awarded).and_raise(award_error)
      allow(credit).to receive(:check_discount_threshold!).and_raise(discount_error)
      allow(VolunteerCredit).to receive(:create!).and_return(credit)

      task.close!(verifier)

      expect(task.reload.status).to eq('closed')
      expect(task.approval_notification).to include('finalized' => true)
      expect(task.approval_notification['outcome']).to include('failed for 1 attendee', attendee_id.to_s,
        'award notification', 'membership discount processing')
      expect(VolunteerCredit).to have_received(:create!).once
      expect(credit).to have_received(:check_discount_threshold!).with(raise_errors: true).once
      expect(credit).to have_received(:notify_discount_error).with(anything, discount_error).once
      expect(Service::ErrorReporter).to have_received(:notify).with(award_error).once
      expect(Service::ErrorReporter).to have_received(:notify).with(discount_error).once
    end

    it 'retains the durable unconfirmed warning when recording the award outcome fails' do
      allow(VolunteerCredit).to receive(:create!).and_return(double(notify_member_credit_awarded: nil, check_discount_threshold!: nil))
      allow(Service::VolunteerApprovalReminder).to receive(:record_outcome!).and_raise('Later metadata write unavailable')

      expect { task.close!(verifier) }.to raise_error('Later metadata write unavailable')

      expect(task.reload.status).to eq('closed')
      expect(task.approval_notification['outcome']).to start_with('Credit award not confirmed')
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        'CORIGINAL', '123.456', a_string_including('⚠️', 'not confirmed'), resolved_channel: true
      )
    end
  end

  context 'when destroying an unlinked task' do
    [false, true].each do |posted|
      it "deletes a pending task with a deleted claimant and #{posted ? 'a posted reminder missing its subject' : 'no reminder'}" do
        @persisted['claimed_by_id'] = BSON::ObjectId.new
        @persisted['approval_notification'] = posted ? receipt.except('subject') : {}
        loaded = persisted_model_with_real_callbacks
        missing_member = Mongoid::Errors::DocumentNotFound.new(Member, { id: loaded.claimed_by_id })
        allow(Member).to receive(:find).with(loaded.claimed_by_id).and_raise(missing_member)

        expect { loaded.destroy }.not_to raise_error

        expect(loaded).to be_destroyed
        expect(@deletion_snapshot['status']).to eq('cancelled')
        expect(@deletion_snapshot['approval_notification']).to include('finalized' => true,
          'subject' => a_string_including('Unknown member'),
          'outcome' => 'Task deletion requested; pending review withdrawn')
        if posted
          expect(Service::SlackConnector).to have_received(:update_slack_message).with(
            'CORIGINAL', '123.456', a_string_including('Unknown member', 'deletion requested'), resolved_channel: true
          ).once
        else
          expect(Service::SlackConnector).not_to have_received(:update_slack_message)
        end
      end
    end

    it 'finalizes a pending reminder through the real destroy callback before removing the record' do
      loaded = persisted_model_with_real_callbacks

      loaded.destroy

      expect(loaded).to be_destroyed
      expect(@deletion_snapshot['status']).to eq('cancelled')
      expect(@deletion_snapshot['approval_notification']).to include('finalized' => true,
        'outcome' => 'Task deletion requested; pending review withdrawn', 'closed_at' => now)
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        'CORIGINAL', '123.456', a_string_including('deletion requested', '6 days'), resolved_channel: true
      ).once
    end

    it 'keeps the cancelled record and receipt for retry when final delivery fails' do
      loaded = persisted_model_with_real_callbacks
      allow(Service::SlackConnector).to receive(:update_slack_message).and_raise('Slack unavailable')

      expect { loaded.destroy }.to raise_error(Error::ServiceUnavailable) do |error|
        expect(error.error).to eq(503)
        expect(error.status).to eq(:service_unavailable)
        expect(error.message).to include('Cannot delete task until its Slack reminders')
      end

      expect(@deletion_snapshot).to be_nil
      expect(@persisted['status']).to eq('cancelled')
      expect(@persisted['approval_notification']['finalized']).to be(false)
      expect(loaded).not_to be_destroyed
      allow(Service::SlackConnector).to receive(:update_slack_message).and_return('ok' => true)
      loaded.destroy
      expect(@deletion_snapshot['approval_notification']['finalized']).to be(true)
      expect(loaded).to be_destroyed
    end
  end

  context 'when rescheduling an open event' do
    let(:receipt) do
      super().merge('started_at' => (now.in_time_zone.to_date - 6).in_time_zone.beginning_of_day.to_time.getutc,
        'subject' => 'Event E8: Community cleanup')
    end
    let(:task) do
      VolunteerEvent.new(title: 'Community cleanup', event_number: 8,
        event_date: now.in_time_zone.to_date - 6, approval_notification: receipt.deep_dup)
    end
    let(:new_date) { now.in_time_zone.to_date + 10 }

    it 'stores the new date, old receipt archive, and empty current receipt in one actual Mongoid command' do
      event = persisted_model_with_real_callbacks

      event.update!(event_date: new_date)

      expect(@model_commands.length).to eq(1)
      selector, command, saved = @model_commands.fetch(0)
      expect(selector).to include('_id' => event.id)
      expect(command.fetch('$set')).to include('event_date' => Time.utc(new_date.year, new_date.month, new_date.day))
      expect(saved.fetch('approval_notification')).to be_empty
      expect(saved.fetch('approval_notification_history')).to contain_exactly(hash_including(
        'ts' => receipt.fetch('ts'), 'channel' => receipt.fetch('channel'), 'started_at' => receipt.fetch('started_at'),
        'closed_at' => now, 'outcome' => a_string_including('Rescheduled'), 'finalized' => false
      ))
      expect(event.reload.approval_notification_history.first['finalized']).to be(true)
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        'CORIGINAL', '123.456', a_string_including('Rescheduled', '6 days'), resolved_channel: true
      ).once
    end

    it 'does not archive or send when actual Mongoid validation rejects the date edit' do
      event = persisted_model_with_real_callbacks
      original = @persisted.deep_dup

      expect { event.update!(title: '', event_date: new_date) }.to raise_error(Mongoid::Errors::Validations)

      expect(@persisted).to eq(original)
      expect(@model_commands).to be_empty
      expect(event.reload.approval_notification).to eq(receipt)
      expect(event.approval_notification_history).to be_empty
      expect(Service::SlackConnector).not_to have_received(:update_slack_message)
      expect(VolunteerApproverNotification).not_to have_received(:preserve_event_receipts!)
    end

    it 'updates a date without manufacturing notification history when no receipt exists' do
      @persisted['approval_notification'] = {}
      event = persisted_model_with_real_callbacks

      event.update!(event_date: new_date)

      expect(event.reload.event_date).to eq(new_date)
      expect(event.approval_notification).to be_empty
      expect(event.approval_notification_history).to be_empty
      expect(@model_commands.length).to eq(1)
      expect(Service::SlackConnector).not_to have_received(:update_slack_message)
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end

    it 'retires the previous dated reminder when the supported date edit clears the schedule' do
      event = persisted_model_with_real_callbacks

      event.update!(event_date: nil)

      expect(event.reload.event_date).to be_nil
      expect(event.approval_notification).to be_empty
      expect(event.approval_notification_history).to contain_exactly(hash_including(
        'ts' => receipt.fetch('ts'), 'closed_at' => now,
        'outcome' => a_string_including('Rescheduled'), 'finalized' => true
      ))
      expect(@model_commands.length).to eq(1)
      expect(Service::SlackConnector).to have_received(:update_slack_message).with(
        'CORIGINAL', '123.456', a_string_including('Rescheduled', '6 days'), resolved_channel: true
      ).once
      Service::VolunteerApprovalReminder.remind!(event, now: now + 40.days)
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end
  end
end
