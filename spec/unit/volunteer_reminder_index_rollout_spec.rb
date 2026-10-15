# Execute the real release task with mocked collections, without Rails or MongoDB:
# ruby -r rspec/autorun spec/unit/volunteer_reminder_index_rollout_spec.rb
require_relative '../spec_helper'
require 'active_support/all'
require 'rake'

RSpec.describe 'volunteer reminder index rollout' do
  let(:task) { Rake::Task['data:ensure_unique_indexes'] }
  let(:specification_class) { Struct.new(:key, :options) }
  let(:task_key) { { status: 1, completed_at: 1 } }
  let(:event_key) { { status: 1, event_date: 1 } }

  around do |example|
    original_application = Rake.application
    Rake.application = Rake::Application.new
    example.run
  ensure
    Rake.application = original_application
  end

  before do
    @collections = {}
    %w[
      Shortcode Shop Card Group Invoice Member RentalType SlackUser Tool
      FixTicket FixTicketEvent FixTicketReveal ToolGroup CheckoutApproverRequest
      VolunteerCredit VolunteerTask VolunteerEvent
    ].each do |name|
      model = Class.new do
        def self.collection; end
        def self.collection_name; end
        def self.index_specifications; end
        def self.create_indexes; end
      end
      stub_const(name, model)
      indexes = double("#{name} indexes", to_a: [], create_one: nil, drop_one: nil)
      collection = double("#{name} collection", aggregate: [], indexes: indexes)
      @collections[name] = collection
      allow(model).to receive(:collection).and_return(collection)
      allow(model).to receive(:collection_name).and_return(name.underscore.pluralize)
      allow(model).to receive(:index_specifications).and_return([])
      allow(model).to receive(:create_indexes)
    end

    allow(VolunteerTask).to receive(:index_specifications).and_return([
      specification_class.new(task_key, {}),
      specification_class.new({ task_number: 1 }, { unique: true })
    ])
    allow(VolunteerEvent).to receive(:index_specifications).and_return([
      specification_class.new(event_key, {}),
      specification_class.new({ event_number: 1 }, { unique: true })
    ])
    allow(CheckoutApproverRequest).to receive(:index_specifications).and_return([
      specification_class.new({ member_id: 1, tool_id: 1, tool_group_id: 1, status: 1 }, { unique: true })
    ])
    allow(VolunteerCredit).to receive(:index_specifications).and_return([
      specification_class.new({ tool_checkout_id: 1 }, { unique: true })
    ])

    stub_const('Mongoid', Module.new do
      def self.default_client; end
    end) unless defined?(Mongoid)
    client = double('MongoDB client')
    allow(client).to receive(:[]) do |name|
      @collections[name] ||= double("#{name} collection",
        indexes: double("#{name} indexes", to_a: [], create_one: nil, drop_one: nil))
    end
    allow(Mongoid).to receive(:default_client).and_return(client)
    Rake::Task.define_task(:environment)
    load File.expand_path('../../lib/tasks/unique_indexes.rake', __dir__)
  end

  it 'ensures only the declared task and event age indexes through the release task' do
    expect { task.invoke }.to output(/volunteer reminder index ensured/).to_stdout

    expect(@collections['VolunteerTask'].indexes).to have_received(:create_one).with(task_key, {}).once
    expect(@collections['VolunteerEvent'].indexes).to have_received(:create_one).with(event_key, {}).once
    [VolunteerTask, VolunteerEvent].each do |model|
      expect(model).not_to have_received(:create_indexes)
      expect(model.collection.indexes).to have_received(:create_one).once
    end
  end

  it 'fails deployment if a reminder index declaration is missing' do
    allow(VolunteerTask).to receive(:index_specifications).and_return([])
    expect do
      expect { task.invoke }.to raise_error(RuntimeError, /Missing volunteer reminder index declaration/)
    end.to output.to_stdout
    expect(@collections['VolunteerTask'].indexes).not_to have_received(:create_one)
  end

  it 'refuses to deploy an accidentally unique reminder index' do
    allow(VolunteerEvent).to receive(:index_specifications).and_return([
      specification_class.new(event_key, { unique: true })
    ])
    expect do
      expect { task.invoke }.to raise_error(RuntimeError, /Volunteer reminder indexes must be nonunique/)
    end.to output.to_stdout
    expect(@collections['VolunteerEvent'].indexes).not_to have_received(:create_one)
  end
end
