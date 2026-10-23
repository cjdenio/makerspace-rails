# Exercise real delivery logic without booting Rails or contacting MongoDB/Slack:
# ruby -r rspec/autorun spec/unit/volunteer_approver_notification_spec.rb
require_relative '../spec_helper'
require 'active_support/all'
require 'bson'
require_relative '../../app/services/volunteer_approver_notification'

RSpec.describe VolunteerApproverNotification do
  let(:now) { Time.utc(2026, 10, 4, 16) }
  let(:shop_id) { 'shop-wood' }
  let(:claimant) { double(id: 'claimant', fullname: 'Pat <Member>') }
  let(:manager) { double(id: 'rm-wood', manages_shop?: true, direct_notifications_suppressed?: false) }
  let(:second_manager) { double(id: 'rm-second', manages_shop?: true, direct_notifications_suppressed?: false) }
  let(:task) do
    VolunteerTask.new(id: 'claim-id', shop_id: shop_id, status: 'pending', title: 'Sort <lumber>',
      display_number: '#17', claimed_by_id: claimant.id, claimed_by: claimant, completed_at: now - 1.hour)
  end
  let(:event) do
    VolunteerEvent.new(id: 'event-id', shop_id: shop_id, status: 'open', title: 'Cleanup',
      display_number: 'E8', event_date: now.in_time_zone.to_date - 1, attendee_count: 3)
  end

  around { |example| Time.use_zone('America/New_York') { example.run } }

  before do
    @selectors = []
    @fail_receipt_writes = false
    stub_const('Mongoid::Errors::DocumentNotFound', Class.new(StandardError)) unless
      defined?(Mongoid::Errors::DocumentNotFound)
    allow(manager).to receive(:reload).and_return(manager)
    allow(second_manager).to receive(:reload).and_return(second_manager)
    record_class = Class.new do
      attr_accessor :id, :shop_id, :status, :title, :display_number, :claimed_by_id,
        :claimed_by, :completed_at, :event_date, :attendee_count, :approver_notifications
      def self.collection; end
      def self.records; @records ||= []; end
      def initialize(attributes)
        @approver_notifications = {}
        attributes.each { |name, value| public_send("#{name}=", value) }
        self.class.records << self
      end
      def reload; self; end
      def document
        instance_variables.to_h do |name|
          value = instance_variable_get(name)
          value = Time.utc(value.year, value.month, value.day) if name == :@event_date && value
          [name == :@id ? '_id' : name.to_s.delete_prefix('@'), value]
        end
      end
    end
    stub_const('VolunteerTask', Class.new(record_class))
    stub_const('VolunteerEvent', Class.new(record_class))
    [VolunteerTask, VolunteerEvent].each do |model|
      collection = double('Atomic collection')
      allow(model).to receive(:collection).and_return(collection)
      allow(collection).to receive(:find) do |selector|
        @selectors << selector
        query = double('Atomic query')
        allow(query).to receive(:first) { model.records.find { |candidate| matches?(candidate.document, selector) }&.document }
        allow(query).to receive(:find_one_and_update) do |update, **_options|
          record = model.records.find { |candidate| matches?(candidate.document, selector) } unless
            @fail_receipt_writes && selector.keys.any? { |key| key.end_with?('.token') }
          if record
            update.fetch('$set', {}).each { |path, value| set_path!(record, path, value) }
            update.fetch('$rename', {}).each do |source, destination|
              value = value_at(record.document, source)
              set_path!(record, destination, value)
              record.approver_notifications.delete(source.delete_prefix('approver_notifications.'))
            end
            record.document
          end
        end
        query
      end
    end
    stub_const('Member', Class.new do
      def self.where(**_conditions); end
    end)
    allow(Member).to receive(:where).with(role: 'resource_manager', resource_manager_shop_ids: shop_id)
      .and_return([manager, second_manager])
    stub_const('SlackUser', Class.new do
      def self.find_by(**_conditions); end
    end)
    allow(SlackUser).to receive(:find_by) do |member_id:|
      double(member_id: member_id, slack_id: "U-#{member_id}", invalidated_at: nil)
    end
    stub_const('ShortUrl', Class.new do
      def self.base_url; end
    end)
    allow(ShortUrl).to receive(:base_url).and_return('https://portal.example.org')
    # Keep the real Service module when Rails is loaded; replacing it would hide
    # Service::DatabaseSafety from the suite-wide DatabaseCleaner hook.
    stub_const('Service', Module.new) unless defined?(Service)
    stub_const('Service::SlackConnector', Module.new do
      def self.send_slack_message(_text, _channel); end
      def self.message_destination_mode; end
    end)
    stub_const('Service::ErrorReporter', Module.new do
      def self.notify(_error); end
    end)
    allow(Service::SlackConnector).to receive(:send_slack_message)
      .and_return({ 'ts' => '123.456', 'channel' => 'DMCHANNEL' })
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('production')
    allow(Service::ErrorReporter).to receive(:notify)
  end

  def value_at(document, path)
    path.split('.').reduce(document) { |value, name| value.is_a?(Hash) ? value[name] : nil }
  end

  def matches?(document, selector)
    selector.all? do |path, expected|
      if path == '$or'
        expected.any? { |condition| matches?(document, condition) }
      else
        actual = value_at(document, path)
        if expected.is_a?(Hash) && expected.key?('$exists')
          actual.present? == expected['$exists']
        elsif expected.is_a?(Hash) && expected.key?('$lt')
          actual && actual < expected['$lt']
        else
          actual == expected
        end
      end
    end
  end

  def set_path!(record, path, value)
    names = path.split('.')
    container = record.approver_notifications
    names[1...-1].each { |name| container = (container[name] ||= {}) }
    container[names.last] = value
  end

  def notify(record = task, at: now)
    described_class.notify!(record, now: at)
  end

  def event_key(date = event.event_date)
    date ? "event_#{date.strftime('%Y%m%d')}" : 'event_undated'
  end

  it 'DMs each assigned manager once with a link to the exact task claim' do
    notify
    notify(at: now + 1.day)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      a_string_including('Pat &lt;Member&gt;', '#17', 'Sort &lt;lumber&gt;',
        '<https://portal.example.org/volunteer?task=claim-id|Review claim>'), 'U-rm-wood').once
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
    expect(task.approver_notifications.values.first.values).to all(include('state' => 'sent', 'ts' => '123.456'))
  end

  it 'targets a child claim and allows a later submission on the same task to notify again' do
    task.id = 'child-claim-id'
    notify
    task.completed_at = now + 1.day
    notify(at: now + 1.day)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      a_string_including('?task=child-claim-id'), 'U-rm-wood').twice
    expect(task.approver_notifications.length).to eq(2)
  end

  it 'sends one event review per manager after its date, regardless of attendance count' do
    notify(event)
    event.attendee_count = 10
    notify(event, at: now + 2.days)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      a_string_including('E8', '3 checked-in attendees', '?event=event-id', 'Review event attendance'), 'U-rm-wood').once
    expect(Service::SlackConnector).to have_received(:send_slack_message).exactly(2).times
  end

  it 'sends one fresh review per manager after a successfully notified event is rescheduled' do
    original_date = event.event_date
    notify(event)
    original_receipts = event.approver_notifications.fetch(event_key(original_date)).deep_dup

    event.event_date = now.in_time_zone.to_date + 3
    [now + 1.day, now + 3.days].each { |time| notify(event, at: time) }
    expect(Service::SlackConnector).to have_received(:send_slack_message).exactly(2).times

    2.times { notify(event, at: now + 4.days) }

    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-wood').twice
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').twice
    expect(event.approver_notifications.fetch(event_key(original_date))).to eq(original_receipts)
    expect(event.approver_notifications.fetch(event_key)).to have_attributes(size: 2)
    expect(event.approver_notifications.fetch(event_key).values).to all(include('state' => 'sent'))
    expect(Service::ErrorReporter).not_to have_received(:notify)
  end

  it 'preserves sent legacy event receipts without reposting on an unchanged schedule' do
    event.approver_notifications['event'] = {
      manager.id => { 'state' => 'sent', 'ts' => 'legacy.ts', 'channel' => 'DLEGACY' }
    }

    2.times { notify(event) }

    expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'U-rm-wood')
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
    expect(event.approver_notifications).not_to have_key('event')
    expect(event.approver_notifications.fetch(event_key).fetch(manager.id)).to include(
      'state' => 'sent', 'ts' => 'legacy.ts', 'channel' => 'DLEGACY'
    )
  end

  it 'preserves a fresh legacy sending lease and retries it only after the lease expires' do
    event.approver_notifications['event'] = {
      manager.id => { 'state' => 'sending', 'token' => 'legacy-token', 'attempted_at' => now }
    }

    notify(event)
    expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'U-rm-wood')
    expect(event.approver_notifications.fetch(event_key).fetch(manager.id)).to include('token' => 'legacy-token')

    2.times { notify(event, at: now + 6.minutes) }

    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-wood').once
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
    expect(event.approver_notifications.fetch(event_key).values).to all(include('state' => 'sent'))
  end

  it 'retries a failed legacy delivery after adopting the current schedule' do
    event.approver_notifications['event'] = { manager.id => { 'state' => 'failed' } }

    2.times { notify(event) }

    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-wood').once
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
    expect(event.approver_notifications.fetch(event_key).values).to all(include('state' => 'sent'))
  end

  it 'preserves both buckets and reports a conflict instead of overwriting date-versioned receipts' do
    event.approver_notifications['event'] = { manager.id => { 'state' => 'sent', 'ts' => 'legacy.ts' } }
    event.approver_notifications[event_key] = { second_manager.id => { 'state' => 'sent', 'ts' => 'current.ts' } }
    existing = event.approver_notifications.deep_dup

    notify(event)

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    expect(event.approver_notifications).to eq(existing)
    expect(Service::ErrorReporter).to have_received(:notify).with(
      an_object_having_attributes(message: 'Legacy event approver receipts could not be bound to the existing schedule')
    ).once
  end

  it 'binds legacy receipts to the previous schedule before a supported reschedule' do
    original_date = event.event_date
    legacy_receipt = { 'state' => 'sent', 'ts' => 'legacy.ts', 'channel' => 'DLEGACY' }
    event.approver_notifications['event'] = { manager.id => legacy_receipt }

    described_class.preserve_event_receipts!(event, event_date: original_date)
    event.event_date = now.in_time_zone.to_date + 3
    notify(event, at: now + 3.days)
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)

    2.times { notify(event, at: now + 4.days) }

    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-wood').once
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
    expect(event.approver_notifications.fetch(event_key(original_date)).fetch(manager.id)).to eq(legacy_receipt)
  end

  it 'does not bind legacy receipts to a schedule that changed before adoption' do
    original_date = event.event_date
    event.approver_notifications['event'] = { manager.id => { 'state' => 'sent' } }
    event.event_date = original_date + 3

    expect { described_class.preserve_event_receipts!(event, event_date: original_date) }.to raise_error(
      'Legacy event approver receipts could not be bound to the existing schedule'
    )

    expect(event.approver_notifications).to have_key('event')
    expect(event.approver_notifications).not_to have_key(event_key(original_date))
  end

  it 'does not notify for unassigned shops, unfinished task claims, or already reviewed records' do
    task.shop_id = nil
    notify
    task.shop_id = shop_id
    task.status = 'claimed'
    notify
    task.status = 'completed'
    notify
    event.status = 'closed'
    notify(event)
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'waits until the event date has passed and skips undated events' do
    [nil, now.in_time_zone.to_date, now.in_time_zone.to_date + 1].each do |date|
      event.event_date = date
      notify(event)
    end
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  %i[future undated].each do |schedule|
    it "retries an event review after its date becomes #{schedule} during lease acquisition" do
      original_date = event.event_date
      rescheduled_date = now.in_time_zone.to_date + 3
      reloaded = 0
      allow(event).to receive(:reload) do
        reloaded += 1
        event.event_date = schedule == :future ? rescheduled_date : nil if reloaded == 2
        event
      end

      notify(event)

      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
      expect(event.approver_notifications.fetch(event_key(original_date)).values).to all(include('state' => 'failed'))
      expect(Service::ErrorReporter).not_to have_received(:notify)

      event.event_date = rescheduled_date
      notify(event, at: now + 1.day)
      notify(event, at: now + 3.days)
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)

      2.times { notify(event, at: now + 4.days) }

      expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-wood').once
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
      expect(event.approver_notifications.keys).to contain_exactly(event_key(original_date), event_key(rescheduled_date))
      expect(event.approver_notifications.fetch(event_key(rescheduled_date)).values).to all(include('state' => 'sent'))
    end
  end

  it 'retries the original event date after a temporary undated reschedule is reversed' do
    original_date = event.event_date
    reloaded = 0
    allow(event).to receive(:reload) do
      reloaded += 1
      event.event_date = nil if reloaded == 2
      event
    end
    notify(event)
    expect(event.approver_notifications.fetch(event_key(original_date)).fetch(manager.id)['state']).to eq('failed')

    event.event_date = original_date
    2.times { notify(event) }

    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-wood').once
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
    expect(event.approver_notifications.fetch(event_key).values).to all(include('state' => 'sent'))
  end

  it 'keeps a closed event receipt obsolete when closure races with lease acquisition' do
    reloaded = 0
    allow(event).to receive(:reload) do
      reloaded += 1
      event.status = 'closed' if reloaded == 2
      event
    end

    notify(event)
    notify(event, at: now + 4.days)

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    expect(event.approver_notifications.fetch(event_key).values).to all(include('state' => 'obsolete'))
    expect(Service::ErrorReporter).not_to have_received(:notify)
  end

  it 'excludes managers who do not manage the shop and the task claimant themselves' do
    allow(manager).to receive(:manages_shop?).and_return(false)
    allow(second_manager).to receive(:id).and_return(claimant.id)
    notify
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'honors the existing revoked/suspended member notification suppression' do
    allow(manager).to receive(:direct_notifications_suppressed?).and_return(true)
    notify
    expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'U-rm-wood')
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
  end

  %i[task event].each do |kind|
    [
      ['removed shop authority', :manages_shop?, false],
      ['suspended or revoked notifications', :direct_notifications_suppressed?, true]
    ].each do |change, predicate, ineligible_value|
      it "retries the #{kind} DM after #{change} is restored following a post-lease change" do
        record = public_send(kind)
        allow(manager).to receive(:reload) do
          allow(manager).to receive(predicate).and_return(ineligible_value)
          manager
        end

        notify(record)

        expect(manager).to have_received(:reload).once
        expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'U-rm-wood')
        expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
        expect(record.approver_notifications.values.first[manager.id]['state']).to eq('failed')
        expect(Service::ErrorReporter).not_to have_received(:notify)

        allow(manager).to receive(:reload).and_return(manager)
        allow(manager).to receive(predicate).and_return(!ineligible_value)
        2.times { notify(record, at: now + 1.minute) }

        expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-wood').once
        expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
        expect(record.approver_notifications.values.first.values).to all(include('state' => 'sent'))
      end
    end

    %i[moved cleared].each do |change|
      it "retries the #{kind} DM after its shop is #{change} during leasing then restored" do
        record = public_send(kind)
        other_shop_id = 'shop-metal'
        [manager, second_manager].each do |recipient|
          allow(recipient).to receive(:manages_shop?).and_return(false)
          allow(recipient).to receive(:manages_shop?).with(shop_id).and_return(true)
        end
        allow(Member).to receive(:where).with(role: 'resource_manager', resource_manager_shop_ids: other_shop_id)
          .and_return([])
        reloaded = 0
        allow(record).to receive(:reload) do
          reloaded += 1
          record.shop_id = change == :moved ? other_shop_id : nil if reloaded == 2
          record
        end

        notify(record)
        notify(record, at: now + 1.minute)

        expect(Service::SlackConnector).not_to have_received(:send_slack_message)
        expect(record.approver_notifications.values.first.values).to all(include('state' => 'failed'))

        record.shop_id = shop_id
        2.times { notify(record, at: now + 2.minutes) }

        expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-wood').once
        expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
        expect(record.approver_notifications.values.first.values).to all(include('state' => 'sent'))
        expect(Service::ErrorReporter).not_to have_received(:notify)
      end
    end
  end

  it 'marks the leased receipt obsolete when the manager was deleted before delivery' do
    allow(manager).to receive(:reload).and_raise(Mongoid::Errors::DocumentNotFound.allocate)

    notify

    expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'U-rm-wood')
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
    expect(task.approver_notifications.values.first[manager.id]['state']).to eq('obsolete')
    expect(Service::ErrorReporter).not_to have_received(:notify)
  end

  it 'keeps deletion obsolete when a no-error reload replaces the manager ID with defaults' do
    original_id = manager.id
    allow(manager).to receive(:reload) do
      allow(manager).to receive(:id).and_return('default-id-after-deletion')
      allow(manager).to receive(:manages_shop?).and_return(false)
      manager
    end

    notify

    expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'U-rm-wood')
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
    expect(task.approver_notifications.values.first[original_id]['state']).to eq('obsolete')
    expect(Service::ErrorReporter).not_to have_received(:notify)
  end

  %w[completed cancelled denied].each do |status|
    it "marks a task receipt obsolete when it becomes #{status} during leasing" do
      reloaded = 0
      allow(task).to receive(:reload) do
        reloaded += 1
        task.status = status if reloaded == 2
        task
      end

      notify
      notify(at: now + 1.minute)

      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
      expect(task.approver_notifications.values.first.values).to all(include('state' => 'obsolete'))
      expect(Service::ErrorReporter).not_to have_received(:notify)
    end
  end

  it 'does not mark an unlinked manager notified and delivers after their Slack account is linked' do
    allow(SlackUser).to receive(:find_by).with(member_id: manager.id).and_return(nil)
    notify
    expect(Service::SlackConnector).to have_received(:send_slack_message).once
    allow(SlackUser).to receive(:find_by).with(member_id: manager.id)
      .and_return(double(member_id: manager.id, slack_id: 'ULINKED', invalidated_at: nil))
    notify
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'ULINKED').once
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
  end

  %i[task event].each do |kind|
    it "retries a #{kind} DM after the manager's Slack link disappears during lease acquisition" do
      record = public_send(kind)
      old_identity = double(member_id: manager.id, slack_id: 'UOLD', invalidated_at: nil)
      allow(SlackUser).to receive(:find_by).with(member_id: manager.id).and_return(old_identity, nil)

      notify(record)

      expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'UOLD')
      expect(record.approver_notifications.values.first[manager.id]['state']).to eq('failed')
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
      expect(Service::ErrorReporter).not_to have_received(:notify)

      current_identity = double(member_id: manager.id, slack_id: 'UCURRENT', invalidated_at: nil)
      allow(SlackUser).to receive(:find_by).with(member_id: manager.id).and_return(current_identity)
      2.times { notify(record, at: now + 1.minute) }

      expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'UCURRENT').once
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
      expect(record.approver_notifications.values.first[manager.id]['state']).to eq('sent')
    end

    it "sends a #{kind} DM to the replacement Slack identity found after the lease" do
      old_identity = double(member_id: manager.id, slack_id: 'UOLD', invalidated_at: nil)
      current_identity = double(member_id: manager.id, slack_id: 'UCURRENT', invalidated_at: nil)
      allow(SlackUser).to receive(:find_by).with(member_id: manager.id).and_return(old_identity, current_identity)
      record = public_send(kind)

      2.times { notify(record) }

      expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'UOLD')
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'UCURRENT').once
      expect(record.approver_notifications.values.first[manager.id]['state']).to eq('sent')
    end
  end

  {
    'invalidated identity' => { member_id: 'rm-wood', slack_id: 'UOLD', invalidated_at: Time.utc(2026, 10, 4, 16) },
    'reassigned identity' => { member_id: 'someone-else', slack_id: 'UOLD', invalidated_at: nil },
    'blank replacement ID' => { member_id: 'rm-wood', slack_id: '', invalidated_at: nil }
  }.each do |reason, attributes|
    it "keeps delivery retryable if the final identity lookup returns #{reason}" do
      old_identity = double(member_id: manager.id, slack_id: 'UOLD', invalidated_at: nil)
      allow(SlackUser).to receive(:find_by).with(member_id: manager.id).and_return(old_identity, double(attributes))

      notify

      expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'UOLD')
      expect(task.approver_notifications.values.first[manager.id]['state']).to eq('failed')
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
      expect(Service::ErrorReporter).not_to have_received(:notify)
    end
  end

  it 'retries only a manager whose initial delivery failed' do
    attempts = 0
    allow(Service::SlackConnector).to receive(:send_slack_message).with(anything, 'U-rm-wood') do
      attempts += 1
      raise 'Slack unavailable' if attempts == 1
      { 'ts' => 'recovered.ts', 'channel' => 'DRECOVERED' }
    end
    notify
    notify(at: now + 1.day)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-wood').twice
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
    expect(Service::ErrorReporter).to have_received(:notify).once
  end

  it 'does not accept an unsuccessful Slack response as a sent notification' do
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return({ 'ok' => false })
    notify
    expect(task.approver_notifications.values.first.values).to all(include('state' => 'failed'))
  end

  it 'prevents a concurrent scan from posting another DM while delivery is in progress' do
    reentered = false
    allow(Service::SlackConnector).to receive(:send_slack_message) do
      unless reentered
        reentered = true
        notify
      end
      { 'ts' => '123.456', 'channel' => 'DMCHANNEL' }
    end
    notify
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-wood').once
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-second').once
  end

  it 'recovers an abandoned sending lease but does not steal a fresh lease' do
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return({ 'ok' => false })
    notify
    receipt = task.approver_notifications.values.first[manager.id]
    receipt['state'] = 'sending'
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return({ 'ts' => 'retry.ts', 'channel' => 'DRETRY' })
    notify(at: now + 1.minute)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-wood').once
    notify(at: now + 6.minutes)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'U-rm-wood').twice
  end

  it 'keeps raw BSON selectors in UTC when called with the application timezone' do
    task.completed_at = (now - 1.hour).in_time_zone
    notify(at: now.in_time_zone)
    lease = @selectors.find { |selector| selector.key?('$or') }
    encoded = BSON::Document.new(lease).to_bson
    decoded = BSON::Document.from_bson(BSON::ByteBuffer.new(encoded.to_s))
    expect(decoded.fetch('completed_at')).to eq(now - 1.hour)
    cutoff = decoded.fetch('$or').last.values.find { |value| value.is_a?(Hash) }.fetch('$lt')
    expect(cutoff).to eq(now - 5.minutes)
  end

  it 'does not deliver for a replacement claim which raced with lease acquisition' do
    reloaded = 0
    allow(task).to receive(:reload) do
      reloaded += 1
      task.completed_at += 1.day if reloaded == 2
      task
    end
    notify
    expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'U-rm-wood')
    expect(task.approver_notifications.values.first[manager.id]['state']).to eq('obsolete')
  end

  it 'reports an uncertain post when the sent receipt cannot be persisted' do
    @fail_receipt_writes = true
    notify
    expect(Service::ErrorReporter).to have_received(:notify).with(
      an_object_having_attributes(message: a_string_including('delivery may have succeeded'))).twice
    expect(task.approver_notifications.values.first.values).to all(include('state' => 'sending'))
  end
end
