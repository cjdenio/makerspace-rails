# Inspect real Mongoid criteria without connecting to a database:
# ruby -r rspec/autorun spec/unit/volunteer_event_reminder_queries_spec.rb
require 'active_support/all'
require 'mongoid'
require_relative '../../app/services/service/volunteer_approval_reminder'

RSpec.describe 'Volunteer approval reminder job query selection' do
  let(:now) { Time.utc(2026, 10, 4, 16) }
  let(:job) { VolunteerEventReminderJob.new }

  before do
    stub_const('ApplicationJob', Class.new do
      def self.queue_as(_queue); end
    end)
    stub_const('VolunteerEventReminderJob', Class.new(ApplicationJob))
    load File.expand_path('../../app/jobs/volunteer_event_reminder_job.rb', __dir__)

    %w[VolunteerTask VolunteerEvent].each do |name|
      model_class = Class.new do
        include Mongoid::Document
        field :status, type: String
        field :completed_at, type: Time
        field :event_date, type: Date
        field :approval_notification, type: Hash, default: {}
        field :approval_notification_history, type: Array, default: []
      end
      stub_const(name, model_class)
    end
    # Any accidental criteria evaluation must fail before opening a socket.
    allow(Mongo::Client).to receive(:new).and_raise('Unit query specs must not connect to MongoDB')
  end

  def unfinished_selectors
    [
      { 'approval_notification.finalized' => false },
      { 'approval_notification_history' => { '$elemMatch' => { 'finalized' => false } } }
    ]
  end

  it 'keeps the overdue task scan limited to the indexed status and submission time' do
    selector = job.send(:reminder_tasks, now).selector
    expect(selector.keys).to contain_exactly('status', 'completed_at')
    expect(selector).to include('status' => 'pending')
    expect(selector.fetch('completed_at')).to include('$ne' => nil, '$lt' => now - 5.days)
  end

  it 'keeps the overdue event scan limited to the indexed status and event date' do
    selector = job.send(:reminder_events, now).selector
    expect(selector.keys).to contain_exactly('status', 'event_date')
    expect(selector).to include('status' => 'open')
    # Mongoid serializes a Date field to its UTC midnight BSON representation.
    expect(selector.fetch('event_date')).to include('$ne' => nil, '$lt' => Time.utc(2026, 9, 29))
  end

  it 'scans retryable current and archived receipts separately without a lifecycle filter' do
    [VolunteerTask, VolunteerEvent].each do |model|
      expect(job.send(:retry_notifications, model).selector).to eq('$or' => unfinished_selectors)
    end
  end

  it 'updates pending age once and retries final deliveries independently, including overlapping records' do
    overdue_task = VolunteerTask.new(status: 'pending', completed_at: now - 6.days)
    overdue_event = VolunteerEvent.new(status: 'open', event_date: now.to_date - 6)
    closed_task = VolunteerTask.new(status: 'cancelled')
    closed_event = VolunteerEvent.new(status: 'closed')
    allow(Time).to receive(:current).and_return(now)
    allow(VolunteerTask).to receive(:where)
      .with(status: 'pending', :completed_at.ne => nil, :shop_id.ne => nil).and_return([])
    allow(VolunteerEvent).to receive(:where)
      .with(status: 'open', :event_date.lt => now.in_time_zone.to_date, :shop_id.ne => nil).and_return([])
    allow(job).to receive(:reminder_tasks).with(now).and_return([overdue_task])
    allow(job).to receive(:reminder_events).with(now).and_return([overdue_event])
    allow(job).to receive(:retry_notifications).with(VolunteerTask).and_return([overdue_task, closed_task])
    allow(job).to receive(:retry_notifications).with(VolunteerEvent).and_return([closed_event])
    allow(Service::VolunteerApprovalReminder).to receive(:remind!)
    allow(Service::VolunteerApprovalReminder).to receive(:sync_closed!)
    stub_const('SystemConfig', Class.new do
      def self.record_run(_name, success:); end
    end)
    allow(SystemConfig).to receive(:record_run)

    job.perform

    [overdue_task, overdue_event].each do |record|
      expect(Service::VolunteerApprovalReminder).to have_received(:remind!).with(record, now: now).once
    end
    [overdue_task, closed_task, closed_event].each do |record|
      expect(Service::VolunteerApprovalReminder).to have_received(:sync_closed!).with(record).once
    end
    expect(Service::VolunteerApprovalReminder).not_to have_received(:remind!).with(closed_task, anything)
    expect(Service::VolunteerApprovalReminder).not_to have_received(:remind!).with(closed_event, anything)
    expect(SystemConfig).to have_received(:record_run).with('volunteer_event_reminder', success: true)
  end
end
