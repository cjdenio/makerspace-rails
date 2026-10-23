# These tests exercise the real reminder service without Rails, MongoDB, or Slack:
# ruby -r rspec/autorun spec/unit/volunteer_approval_reminder_spec.rb
require 'active_support/all'
require 'bson'
require_relative '../spec_helper'
require_relative '../../app/services/service/volunteer_approval_reminder'

RSpec.describe Service::VolunteerApprovalReminder do
  let(:now) { Time.utc(2026, 10, 4, 16) }
  let(:claimant) { double(fullname: 'Pat <Member> & Friends') }
  let(:task) do
    VolunteerTask.new(status: 'pending', title: 'Clean <shop>', display_number: '#17',
      claimed_by: claimant, completed_at: now - 6.days)
  end
  let(:event) do
    VolunteerEvent.new(status: 'open', title: 'Cleanup', display_number: 'E8',
      event_date: now.in_time_zone.to_date - 6, attendee_count: 2)
  end

  before do
    @raw_notification_updates = []
    record_class = Class.new do
      attr_accessor :id, :status, :title, :display_number, :claimed_by, :completed_at,
        :event_date, :attendee_count, :approval_notification, :approval_notification_history

      def self.records
        @records ||= []
      end

      def self.collection; end

      def initialize(attributes)
        @id = self.class.records.length + 1
        @approval_notification = {}
        @approval_notification_history = []
        attributes.each { |name, value| public_send("#{name}=", value) }
        self.class.records << self
      end

      def set(attributes)
        attributes.each { |name, value| public_send("#{name}=", value) }
      end

      def reload
        self
      end

      def event_date=(value)
        @event_date = value&.to_date
      end

      def document
        instance_variables.to_h do |name|
          key = name == :@id ? '_id' : name.to_s.delete_prefix('@')
          value = instance_variable_get(name)
          value = Time.utc(value.year, value.month, value.day) if name == :@event_date && value
          [key, value]
        end
      end
    end
    stub_const('VolunteerTask', Class.new(record_class))
    stub_const('VolunteerEvent', Class.new(record_class))
    [VolunteerTask, VolunteerEvent].each do |model_class|
      collection = double('In-memory collection')
      allow(model_class).to receive(:collection).and_return(collection)
      allow(collection).to receive(:find) do |selector|
        query = double('Atomic update')
        allow(query).to receive(:read).with(mode: :primary).and_return(query)
        allow(query).to receive(:first) do
          model_class.records.find { |candidate| matches_document?(candidate.document, selector) }&.document
        end
        allow(query).to receive(:find_one_and_update) do |update, **_options|
          @raw_notification_updates << [selector.deep_dup, update.deep_dup]
          @before_atomic_update&.call(selector, update)
          record = model_class.records.find { |candidate| matches_document?(candidate.document, selector) }
          if record
            apply_document_update(record, update)
            record.document
          end
        end
        query
      end
    end
    stub_const('Service::SlackConnector', Module.new do
      def self.admin_channel; end
      def self.message_destination_mode; end
      def self.send_slack_message(_text, _channel); end
      def self.update_slack_message(_channel, _ts, _text, resolved_channel: false); end
      def self.delete_slack_message(_channel, _ts, resolved_channel: false); end
    end)
    stub_const('Service::ErrorReporter', Module.new do
      def self.notify(_error); end
    end)
    allow(Service::SlackConnector).to receive(:admin_channel).and_return('administrators')
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('production')
    allow(Service::SlackConnector).to receive(:send_slack_message)
      .and_return({ 'ts' => '123.456', 'channel' => 'CADMIN' })
    allow(Service::SlackConnector).to receive(:update_slack_message).and_return({ 'ok' => true })
    allow(Service::SlackConnector).to receive(:delete_slack_message).and_return({ 'ok' => true })
    allow(Service::ErrorReporter).to receive(:notify)
  end

  around do |example|
    Time.use_zone('America/New_York') { example.run }
  end

  def post_reminder(record = task, at: now)
    described_class.remind!(record, now: at)
    record.approval_notification
  end

  def close_reminder(record = task, outcome: 'Approved', at: now + 2.days)
    record.set(described_class.outcome_attributes(record, outcome: outcome, closed_at: at))
    described_class.sync_closed!(record)
  end

  def reschedule_event(date, at: now)
    updates = { '$set' => { 'event_date' => Time.utc(date.year, date.month, date.day) } }
    described_class.reschedule_event!(event, updates, previous_date: event.event_date, now: at)
    event.reload
    described_class.sync_closed!(event)
  end

  # A small database adapter exercises the service's real atomic selectors and
  # dotted-field updates. It never opens MongoDB or replaces persistence helpers.
  def value_at(document, path)
    path.split('.').reduce(document) do |value, key|
      value.is_a?(Array) ? value[key.to_i] : value&.[](key)
    end
  end

  def matches_document?(document, selector)
    selector.all? do |path, expected|
      actual = value_at(document, path)
      if path == '$or'
        expected.any? { |branch| matches_document?(document, branch) }
      elsif expected.is_a?(Hash) && expected.key?('$not')
        condition = expected.fetch('$not').fetch('$elemMatch')
        Array(actual).none? { |saved| matches_document?(saved, condition) }
      elsif expected.is_a?(Hash) && expected.key?('$elemMatch')
        Array(actual).any? { |saved| matches_document?(saved, expected.fetch('$elemMatch')) }
      else
        actual == expected
      end
    end
  end

  def apply_document_update(record, update)
    update.fetch('$set', {}).each do |path, value|
      names = path.split('.')
      if names.length == 1
        record.set(names.first => value)
      else
        container = value_at(record.document, names.take(names.length - 1).join('.'))
        container.is_a?(Array) ? container[names.last.to_i] = value : container[names.last] = value
      end
    end
    update.fetch('$push', {}).each do |path, value|
      values = value.is_a?(Hash) && value.key?('$each') ? value.fetch('$each') : [value]
      value_at(record.document, path).concat(values)
    end
  end

  it 'does not post at exactly five elapsed days, but posts one second later' do
    task.completed_at = now - 5.days
    post_reminder
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    expect(task.approval_notification).to eq({})

    post_reminder(at: now + 1.second)
    expect(Service::SlackConnector).to have_received(:send_slack_message)
      .with(a_string_including('5 days'), 'administrators').once
  end

  it 'saves the returned channel and timestamp on the submitted task' do
    receipt = post_reminder
    expect(receipt).to include('ts' => '123.456', 'channel' => 'CADMIN', 'started_at' => task.completed_at)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      a_string_including('#17', '6 days', 'volunteer approver', 'Clean &lt;shop&gt;',
        'Pat &lt;Member&gt; &amp; Friends'), 'administrators')
  end

  it 'does not remind about work still claimed or a submission without a completion date' do
    task.status = 'claimed'
    post_reminder
    task.status = 'pending'
    task.completed_at = nil
    post_reminder
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'waits more than five calendar days after an event date' do
    event.event_date = now.in_time_zone.to_date - 5
    post_reminder(event)
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)

    event.event_date -= 1
    receipt = post_reminder(event)
    expect(receipt['started_at']).to eq(event.event_date.in_time_zone.beginning_of_day)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      a_string_including('E8', '6 days', '2 checked-in attendees', 'close the event'), 'administrators')
  end

  it 'does not remind about closed, future, or undated events' do
    event.status = 'closed'
    post_reminder(event)
    event.status = 'open'
    event.event_date = now.in_time_zone.to_date + 1
    post_reminder(event)
    event.event_date = nil
    post_reminder(event)
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'updates the existing message with a new duration in its original channel' do
    post_reminder
    allow(Service::SlackConnector).to receive(:admin_channel).and_return('new-administrators')
    post_reminder(at: now + 3.days)
    expect(Service::SlackConnector).to have_received(:send_slack_message).once
    expect(Service::SlackConnector).to have_received(:update_slack_message)
      .with('CADMIN', '123.456', a_string_including('9 days'), resolved_channel: true).once
  end

  it 'refreshes the current event roster while keeping the same notification timestamp' do
    post_reminder(event)
    event.attendee_count = 3
    post_reminder(event, at: now + 1.day)
    expect(Service::SlackConnector).to have_received(:send_slack_message).once
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CADMIN', '123.456', a_string_including('3 checked-in attendees', '7 days'), resolved_channel: true)
  end

  it 'reports a failed initial post without saving successful-delivery fields' do
    allow(Service::SlackConnector).to receive(:send_slack_message).and_raise('Slack unavailable')
    post_reminder
    expect(task.approval_notification).not_to include('ts', 'channel')
    expect(Service::ErrorReporter).to have_received(:notify).with(an_instance_of(RuntimeError))
  end

  [nil, { 'ts' => '123.456' }, { 'channel' => 'CADMIN' }].each do |response|
    it "does not save an incomplete Slack receipt: #{response.inspect}" do
      allow(Service::SlackConnector).to receive(:send_slack_message).and_return(response)
      post_reminder
      expect(task.approval_notification).not_to include('ts', 'channel')
      expect(Service::ErrorReporter).to have_received(:notify)
    end
  end

  it 'accepts a symbol-keyed Slack response' do
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return(ts: '789.123', channel: 'COTHER')
    expect(post_reminder).to include('ts' => '789.123', 'channel' => 'COTHER')
  end

  it 'accepts Slack responses that expose timestamp and channel accessors' do
    response = Struct.new(:ts, :channel).new('789.123', 'COTHER')
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return(response)
    expect(post_reminder).to include('ts' => '789.123', 'channel' => 'COTHER')
  end

  it 'keeps the original receipt after a failed update without posting a replacement' do
    saved = post_reminder.deep_dup
    allow(Service::SlackConnector).to receive(:update_slack_message).and_raise('message_not_found')
    post_reminder(at: now + 3.days)
    expect(task.approval_notification).to eq(saved)
    expect(Service::SlackConnector).to have_received(:send_slack_message).once
    expect(Service::ErrorReporter).to have_received(:notify)
  end

  %w[Approved Denied].each do |outcome|
    it "edits the message to #{outcome.downcase} with the original eight-day review duration" do
      post_reminder
      close_reminder(outcome: outcome)
      expect(Service::SlackConnector).to have_received(:update_slack_message)
        .with('CADMIN', '123.456', a_string_including(outcome, 'Review closed after 8 days'), resolved_channel: true).once
      expect(task.approval_notification['finalized']).to be(true)
      described_class.sync_closed!(task)
      expect(Service::SlackConnector).to have_received(:update_slack_message).once
    end
  end

  it 'retains the task subject after a denial clears its claimant and dates' do
    post_reminder
    task.set(described_class.outcome_attributes(task, outcome: 'Denied', closed_at: now))
    task.claimed_by = nil
    task.completed_at = nil
    task.status = 'available'
    described_class.sync_closed!(task)
    expect(Service::SlackConnector).to have_received(:update_slack_message)
      .with('CADMIN', '123.456', a_string_including('Pat &lt;Member&gt;', 'Denied', '6 days'), resolved_channel: true)
  end

  it 'keeps failed final delivery retryable and preserves the closure date' do
    post_reminder
    allow(Service::SlackConnector).to receive(:update_slack_message).and_raise('Slack unavailable')
    close_reminder
    expect(task.approval_notification['finalized']).to be(false)
    expect(task.approval_notification['closed_at']).to eq(now + 2.days)

    allow(Service::SlackConnector).to receive(:update_slack_message).and_return({ 'ok' => true })
    described_class.remind!(task, now: now + 20.days)
    expect(task.approval_notification['finalized']).to be(true)
    expect(Service::SlackConnector).to have_received(:update_slack_message)
      .with('CADMIN', '123.456', a_string_including('8 days'), resolved_channel: true).twice
    expect(Service::SlackConnector).to have_received(:send_slack_message).once
  end

  it 'archives a failed denial notification before a new claim and retries that original message' do
    saved = post_reminder
    task.set(described_class.outcome_attributes(task, outcome: 'Denied', closed_at: now))
    described_class.reset!(task, previous_notification: task.approval_notification.deep_dup)
    expect(task.approval_notification).to eq({})
    expect(task.approval_notification_history).to contain_exactly(hash_including(
      'ts' => saved['ts'], 'outcome' => 'Denied', 'finalized' => false))

    task.status = 'claimed'
    task.completed_at = nil
    described_class.remind!(task, now: now + 20.days)
    expect(Service::SlackConnector).to have_received(:update_slack_message)
      .with('CADMIN', '123.456', a_string_including('Denied', '6 days'), resolved_channel: true)
    expect(task.approval_notification_history.first['finalized']).to be(true)
    expect(Service::SlackConnector).to have_received(:send_slack_message).once
  end

  it 'keeps separate timestamps for two successive submissions on one standard task' do
    post_reminder
    close_reminder(outcome: 'Denied')
    described_class.reset!(task, previous_notification: task.approval_notification.deep_dup)
    task.completed_at = now + 1.day
    allow(Service::SlackConnector).to receive(:send_slack_message)
      .and_return({ 'ts' => '222.333', 'channel' => 'CADMIN' })
    post_reminder(at: now + 7.days)
    expect(task.approval_notification['ts']).to eq('222.333')
    expect(task.approval_notification_history.first['ts']).to eq('123.456')
    expect(Service::SlackConnector).to have_received(:send_slack_message).twice
  end

  it 'does not build final-outcome attributes without a posted notification' do
    task.set(described_class.outcome_attributes(task, outcome: 'Approved', closed_at: now))
    expect(task.approval_notification).to include('outcome' => 'Approved', 'finalized' => true)
    described_class.sync_closed!(task)
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
  end

  it 'uses event calendar dates for final durations across a daylight-saving transition' do
    event.event_date = Date.new(2026, 10, 29)
    posted_at = Time.zone.local(2026, 11, 4, 0, 30)
    post_reminder(event, at: posted_at)
    close_reminder(event, outcome: 'Closed; attendee credits processed', at: Time.zone.local(2026, 11, 5, 0, 30))
    expect(Service::SlackConnector).to have_received(:update_slack_message)
      .with('CADMIN', '123.456', a_string_including('Review closed after 7 days'), resolved_channel: true)
  end

  it 'records the actual Slack destination mode on a new notification' do
    expect(post_reminder).to include('destination_mode' => 'production')
  end

  it 'does not edit a production message after the Slack destination mode changes to test' do
    saved = post_reminder.deep_dup
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('test')
    post_reminder(at: now + 1.day)
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
    expect(Service::SlackConnector).to have_received(:send_slack_message).once
    expect(task.approval_notification).to eq(saved)
    expect(Service::ErrorReporter).to have_received(:notify)
  end

  it 'keeps a final update retryable while its Slack destination mode differs' do
    post_reminder
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('test')
    close_reminder
    expect(Service::SlackConnector).not_to have_received(:update_slack_message)
    expect(task.approval_notification['finalized']).to be(false)

    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('production')
    described_class.sync_closed!(task)
    expect(task.approval_notification['finalized']).to be(true)
    expect(Service::SlackConnector).to have_received(:update_slack_message).once
  end

  it 'attaches a first-post receipt without overwriting an approval that completed during the Slack request' do
    allow(Service::SlackConnector).to receive(:send_slack_message) do
      snapshot = described_class.outcome_attributes(task, outcome: 'Approved', closed_at: now)
        .fetch(:approval_notification)
      task.status = 'completed'
      described_class.record_outcome!(task, snapshot, expected_status: 'completed')
      { 'ts' => '123.456', 'channel' => 'CADMIN' }
    end
    post_reminder
    expect(task.approval_notification).to include('ts' => '123.456', 'outcome' => 'Approved',
      'closed_at' => now, 'finalized' => true)
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CADMIN', '123.456', a_string_including('Approved', '6 days'), resolved_channel: true)
  end

  it 'attaches an in-flight post to the archived denial after a standard task is reclaimed' do
    allow(Service::SlackConnector).to receive(:send_slack_message) do
      snapshot = described_class.outcome_attributes(task, outcome: 'Denied', closed_at: now)
        .fetch(:approval_notification)
      task.status = 'available'
      task.completed_at = nil
      described_class.record_outcome!(task, snapshot, expected_status: 'available')
      previous = task.approval_notification.deep_dup
      task.status = 'claimed'
      described_class.reset!(task, previous_notification: previous)
      { 'ts' => '123.456', 'channel' => 'CADMIN' }
    end
    post_reminder
    expect(task.approval_notification).to eq({})
    expect(task.approval_notification_history).to contain_exactly(hash_including(
      'ts' => '123.456', 'outcome' => 'Denied', 'closed_at' => now, 'finalized' => true))
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CADMIN', '123.456', a_string_including('Denied', '6 days'), resolved_channel: true)
  end

  it 'retains the first registered post and deletes a competing duplicate post' do
    allow(Service::SlackConnector).to receive(:send_slack_message) do
      task.approval_notification.merge!('ts' => 'WINNER', 'channel' => 'CADMIN', 'destination_mode' => 'production')
      { 'ts' => 'LOSER', 'channel' => 'CADMIN' }
    end
    post_reminder
    expect(task.approval_notification['ts']).to eq('WINNER')
    expect(Service::SlackConnector).to have_received(:delete_slack_message)
      .with('CADMIN', 'LOSER', resolved_channel: true).once
  end

  it 'restores final text when an age refresh races with a completed review' do
    post_reminder
    allow(Service::SlackConnector).to receive(:update_slack_message) do |_channel, _ts, text, **_options|
      if text.start_with?('⏰')
        snapshot = described_class.outcome_attributes(task, outcome: 'Approved', closed_at: now + 1.day)
          .fetch(:approval_notification)
        task.status = 'completed'
        described_class.record_outcome!(task, snapshot, expected_status: 'completed')
        # The reviewer has already delivered final text before the age update returns.
        task.approval_notification['finalized'] = true
      end
      { 'ok' => true }
    end
    post_reminder(at: now + 3.days)
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CADMIN', '123.456', a_string_including('Approved', '7 days'), resolved_channel: true)
    expect(task.approval_notification).to include('closed_at' => now + 1.day, 'finalized' => true)
  end

  it 'finalizes an archived denial without changing a new claim created during chat.update' do
    post_reminder
    task.set(described_class.outcome_attributes(task, outcome: 'Denied', closed_at: now))
    new_receipt = { 'started_at' => now + 1.day, 'ts' => 'NEW', 'channel' => 'CADMIN' }
    allow(Service::SlackConnector).to receive(:update_slack_message) do
      previous = task.approval_notification.deep_dup
      task.status = 'claimed'
      described_class.reset!(task, previous_notification: previous)
      task.approval_notification = new_receipt.deep_dup
      { 'ok' => true }
    end
    described_class.sync_closed!(task)
    expect(task.approval_notification).to eq(new_receipt)
    expect(task.approval_notification_history.first).to include('ts' => '123.456', 'finalized' => true)
  end

  it 'archives a late outcome write instead of overwriting a new submission' do
    post_reminder
    snapshot = described_class.outcome_attributes(task, outcome: 'Denied', closed_at: now)
      .fetch(:approval_notification)
    new_receipt = { 'started_at' => now + 1.day, 'ts' => 'NEW', 'channel' => 'CADMIN' }
    task.approval_notification = new_receipt.deep_dup
    task.completed_at = now + 1.day
    described_class.record_outcome!(task, snapshot, expected_status: 'available')
    described_class.record_outcome!(task, snapshot, expected_status: 'available')
    expect(task.approval_notification).to eq(new_receipt)
    expect(task.approval_notification_history).to contain_exactly(hash_including(
      'ts' => '123.456', 'outcome' => 'Denied', 'closed_at' => now))
  end

  it 'guards initial registration by submission and writes only receipt delivery fields' do
    post_reminder
    intent_selector, = @raw_notification_updates.first
    expect(intent_selector).to include('_id' => task.id, 'status' => 'pending',
      'completed_at' => task.completed_at, 'approval_notification.started_at' => nil,
      'approval_notification.ts' => nil)
    receipt_selector, receipt_update = @raw_notification_updates.find do |_selector, update|
      update.fetch('$set', {}).key?('approval_notification.ts')
    end
    expect(receipt_selector).to include('_id' => task.id,
      'approval_notification.started_at' => task.completed_at, 'approval_notification.ts' => nil)
    expect(receipt_update.fetch('$set')).to include('approval_notification.ts' => '123.456',
      'approval_notification.channel' => 'CADMIN')
    expect(receipt_update.fetch('$set')).not_to include('approval_notification',
      'approval_notification.outcome', 'approval_notification.closed_at')
  end

  it 'guards finalization by timestamp, submission, saved outcome, and exact closure time' do
    post_reminder
    close_reminder
    selector, update = @raw_notification_updates.find do |_selector, change|
      change.fetch('$set', {}) == { 'approval_notification.finalized' => true }
    end
    expect(selector).to include('_id' => task.id, 'approval_notification.ts' => '123.456',
      'approval_notification.started_at' => task.completed_at,
      'approval_notification.closed_at' => now + 2.days, 'approval_notification.outcome' => 'Approved')
    expect(update).to eq('$set' => { 'approval_notification.finalized' => true })
  end

  it 'persists native UTC timestamps through BSON without changing the local activity date or elapsed days' do
    posted_at = Time.zone.local(2026, 10, 4, 12)
    closed_at = Time.zone.local(2026, 10, 6, 9, 30)
    post_reminder(event, at: posted_at)
    receipt = event.approval_notification
    expect(receipt['started_at']).to be_instance_of(Time)
    expect(receipt['started_at']).to eq(Time.utc(2026, 9, 28, 4))

    snapshot = described_class.outcome_attributes(event,
      outcome: 'Closed; attendee credits processed', closed_at: closed_at).fetch(:approval_notification)
    expect(snapshot['closed_at']).to be_instance_of(Time)
    expect(snapshot['closed_at']).to eq(Time.utc(2026, 10, 6, 13, 30))
    encoded = BSON::Document.new(snapshot).to_bson
    saved = BSON::Document.from_bson(BSON::ByteBuffer.new(encoded.to_s))
    expect(saved['started_at']).to eq(Time.utc(2026, 9, 28, 4))
    expect(saved['closed_at']).to eq(Time.utc(2026, 10, 6, 13, 30))

    event.approval_notification = saved
    event.status = 'closed'
    described_class.sync_closed!(event)
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CADMIN', '123.456', a_string_including('Review closed after 8 days'), resolved_channel: true)
    finalized_selector, = @raw_notification_updates.find do |_selector, update|
      update.fetch('$set', {}) == { 'approval_notification.finalized' => true }
    end
    expect(finalized_selector['approval_notification.started_at']).to be_instance_of(Time)
    expect(finalized_selector['approval_notification.closed_at']).to be_instance_of(Time)
  end

  it 'archives and finalizes the old schedule before posting a new overdue reminder from the new date' do
    old_receipt = post_reminder(event).deep_dup
    next_date = now.in_time_zone.to_date + 10

    reschedule_event(next_date)

    expect(event.event_date).to eq(next_date)
    expect(event.approval_notification).to be_empty
    expect(event.approval_notification_history).to contain_exactly(hash_including(
      'ts' => old_receipt.fetch('ts'), 'started_at' => old_receipt.fetch('started_at'),
      'closed_at' => now, 'outcome' => a_string_including('Rescheduled'), 'finalized' => true
    ))
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CADMIN', '123.456', a_string_including('Rescheduled', '6 days'), resolved_channel: true
    ).once
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return('ts' => 'NEW', 'channel' => 'CNEW')

    fresh_receipt = post_reminder(event, at: (next_date + 6).in_time_zone.change(hour: 12))

    expect(fresh_receipt).to include('ts' => 'NEW', 'channel' => 'CNEW',
      'started_at' => next_date.in_time_zone.beginning_of_day.to_time.getutc)
    expect(event.approval_notification_history.first['ts']).to eq('123.456')
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      a_string_including(next_date.strftime('%m/%d/%Y'), '6 days'), 'administrators'
    ).once
  end

  it 'retries a failed reschedule message without reposting while the new date is still in the future' do
    post_reminder(event)
    allow(Service::SlackConnector).to receive(:update_slack_message).and_raise('Slack unavailable')

    reschedule_event(now.in_time_zone.to_date + 10)

    expect(event.approval_notification).to be_empty
    expect(event.approval_notification_history.first).to include('closed_at' => now, 'finalized' => false)
    allow(Service::SlackConnector).to receive(:update_slack_message).and_return('ok' => true)
    post_reminder(event, at: now + 1.day)

    expect(event.approval_notification).to be_empty
    expect(event.approval_notification_history.first['finalized']).to be(true)
    expect(Service::SlackConnector).to have_received(:send_slack_message).once
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CADMIN', '123.456', a_string_including('Rescheduled', '6 days'), resolved_channel: true
    ).twice
  end

  it 'registers an in-flight old post on its archived intent after rescheduling back to the same date' do
    original_date = event.event_date
    attempts = 0
    allow(Service::SlackConnector).to receive(:send_slack_message) do
      attempts += 1
      if attempts == 1
        reschedule_event(original_date + 20)
        reschedule_event(original_date)
        post_reminder(event)
        { 'ts' => 'OLD-INFLIGHT', 'channel' => 'COLD' }
      else
        { 'ts' => 'NEW-INTENT', 'channel' => 'CNEW' }
      end
    end

    post_reminder(event)

    expect(event.approval_notification).to include('ts' => 'NEW-INTENT', 'channel' => 'CNEW')
    expect(event.approval_notification['closed_at']).to be_nil
    expect(event.approval_notification_history).to contain_exactly(hash_including(
      'ts' => 'OLD-INFLIGHT', 'channel' => 'COLD', 'outcome' => a_string_including('Rescheduled'),
      'closed_at' => now, 'finalized' => true
    ))
    archived = event.approval_notification_history.first
    expect(archived.fetch('generation_id')).not_to eq(event.approval_notification.fetch('generation_id'))
    expect(archived.fetch('started_at')).to eq(event.approval_notification.fetch('started_at'))
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'COLD', 'OLD-INFLIGHT', a_string_including('Rescheduled', '6 days'), resolved_channel: true
    ).once
    expect(Service::SlackConnector).not_to have_received(:delete_slack_message)
    expect(Service::SlackConnector).to have_received(:send_slack_message).twice
  end

  it 'retries the date change when a concurrent post registers its timestamp after the archive snapshot was read' do
    intent = described_class.send(:prepare_intent!, event, now).deep_dup
    @before_atomic_update = proc do |_selector, update|
      next unless update.fetch('$set', {}).key?('event_date')

      @before_atomic_update = nil
      event.approval_notification = intent.merge(
        'ts' => 'LATEST', 'channel' => 'CLATEST', 'destination_mode' => 'production'
      )
    end

    reschedule_event(now.in_time_zone.to_date + 10)

    expect(event.approval_notification).to be_empty
    expect(event.approval_notification_history).to contain_exactly(hash_including(
      'ts' => 'LATEST', 'channel' => 'CLATEST', 'generation_id' => intent.fetch('generation_id'),
      'outcome' => a_string_including('Rescheduled'), 'finalized' => true
    ))
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CLATEST', 'LATEST', a_string_including('Rescheduled', '6 days'), resolved_channel: true
    ).once
    expect(Service::SlackConnector).not_to have_received(:delete_slack_message)
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'attaches a legacy in-flight post to its archive when rescheduled back to the same date with no new intent' do
    original_date = event.event_date
    original_start = original_date.in_time_zone.beginning_of_day.to_time.getutc
    event.approval_notification = {
      'started_at' => original_start, 'subject' => 'Legacy Event E8: Cleanup', 'finalized' => true
    }
    allow(Service::SlackConnector).to receive(:send_slack_message) do
      reschedule_event(original_date + 20)
      reschedule_event(original_date)
      { 'ts' => 'LEGACY-INFLIGHT', 'channel' => 'CLEGACY' }
    end

    post_reminder(event)

    expect(event.approval_notification).to be_empty
    expect(event.approval_notification_history).to contain_exactly(hash_including(
      'ts' => 'LEGACY-INFLIGHT', 'channel' => 'CLEGACY', 'started_at' => original_start,
      'outcome' => a_string_including('Rescheduled'), 'closed_at' => now, 'finalized' => true
    ))
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CLEGACY', 'LEGACY-INFLIGHT', a_string_including('Rescheduled', '6 days'), resolved_channel: true
    ).once
    expect(Service::SlackConnector).not_to have_received(:delete_slack_message)
    expect(Service::SlackConnector).to have_received(:send_slack_message).once
  end

  %i[post update].each do |operation|
    it "removes an in-flight #{operation} message when task deletion wins before the receipt reload" do
      stub_const('Mongoid::Errors::DocumentNotFound', Class.new(StandardError))
      post_reminder if operation == :update
      deleted = false
      allow(task).to receive(:reload) do
        raise Mongoid::Errors::DocumentNotFound, 'Task was deleted' if deleted
        task
      end
      if operation == :post
        allow(Service::SlackConnector).to receive(:send_slack_message) do
          deleted = true
          VolunteerTask.records.delete(task)
          { 'ts' => 'LATE', 'channel' => 'CLATE' }
        end
      else
        allow(Service::SlackConnector).to receive(:update_slack_message) do
          deleted = true
          VolunteerTask.records.delete(task)
          { 'ok' => true }
        end
      end

      post_reminder

      channel, timestamp = operation == :post ? %w[CLATE LATE] : %w[CADMIN 123.456]
      expect(Service::SlackConnector).to have_received(:delete_slack_message).with(
        channel, timestamp, resolved_channel: true
      ).once
      expect(Service::ErrorReporter).not_to have_received(:notify)
    end
  end

  it 'keeps an existing task reminder when its claimant lookup raises DocumentNotFound' do
    stub_const('Mongoid::Errors::DocumentNotFound', Class.new(StandardError))
    saved = post_reminder.deep_dup
    missing_member = Mongoid::Errors::DocumentNotFound.new('Claimant was deleted')
    allow(task).to receive(:claimed_by).and_raise(missing_member)

    post_reminder

    expect(task.approval_notification).to eq(saved)
    expect(Service::SlackConnector).not_to have_received(:delete_slack_message)
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CADMIN', '123.456', a_string_including('Unknown member', '6 days'), resolved_channel: true
    ).once
    expect(Service::ErrorReporter).not_to have_received(:notify)
    allow(task).to receive(:claimed_by).and_return(claimant)
    post_reminder(at: now + 1.day)
    expect(Service::SlackConnector).to have_received(:update_slack_message).with(
      'CADMIN', '123.456', a_string_including('7 days'), resolved_channel: true
    ).once
    expect(Service::SlackConnector).to have_received(:send_slack_message).once
  end

  it 'keeps the message if checking whether the reminder record exists fails' do
    stub_const('Mongoid::Errors::DocumentNotFound', Class.new(StandardError))
    saved = post_reminder.deep_dup
    allow(Service::SlackConnector).to receive(:update_slack_message)
      .and_raise(Mongoid::Errors::DocumentNotFound, 'Task disappeared during update')
    primary_query = double('Primary query')
    allow(primary_query).to receive(:read).with(mode: :primary).and_return(primary_query)
    allow(primary_query).to receive(:first).and_raise('Database unavailable')
    allow(VolunteerTask.collection).to receive(:find).with('_id' => task.id).and_return(primary_query)

    post_reminder

    expect(task.approval_notification).to eq(saved)
    expect(Service::SlackConnector).not_to have_received(:delete_slack_message)
    expect(Service::ErrorReporter).to have_received(:notify).with(have_attributes(message: 'Database unavailable')).once
  end
end
