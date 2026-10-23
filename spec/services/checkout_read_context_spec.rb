require 'rails_helper'

RSpec.describe CheckoutReadContext do
  let(:viewer) { create(:member, :current) }
  let(:shop) { create(:shop) }
  let(:prerequisite) { create(:tool, shop: shop) }
  let(:tool) { create(:tool, shop: shop, prerequisite_ids: [prerequisite.id.to_s], notes: 'Cabinet combination') }

  def serialize(rows, serializer, **options)
    ActiveModelSerializers::SerializableResource.new(rows, each_serializer: serializer,
      adapter: :attributes, scope: viewer, **options).as_json
  end

  class ReadCounter
    attr_reader :commands
    def initialize
      @commands = []
    end
    def started(event)
      @commands << event.command_name if %w[find aggregate count distinct].include?(event.command_name)
    end
    def succeeded(_event); end
    def failed(_event); end
  end

  def reads
    counter = ReadCounter.new
    client = Mongoid.default_client
    client.subscribe(Mongo::Monitoring::COMMAND, counter)
    yield
    counter.commands
  ensure
    client.unsubscribe(Mongo::Monitoring::COMMAND, counter)
  end

  it 'preserves shop counts and prerequisite names with one facet, including empty shops' do
    tool
    shop.update!(reservation_prerequisite_tool_ids: [prerequisite.id.to_s])
    rows = [shop, create(:shop)]
    expected = serialize(rows, ShopSerializer)
    context = nil
    expect(reads { context = described_class.for_shops(rows) }).to eq(['aggregate', 'find'])
    expect(reads { expect(serialize(rows, ShopSerializer, checkout_context: context)).to eq(expected) }).to be_empty
    expect(context.tool_count(rows.last)).to eq(0)
    expect(described_class.for_shops([]).shops).to be_empty
  end

  it 'preserves tool serialization without per-tool database queries' do
    create(:tool_checkout, member: viewer, tool: prerequisite)
    CheckoutApprover.create!(member: viewer, tool_ids: [tool.id.to_s])
    rows = [tool, prerequisite]
    expected = serialize(rows, ToolSerializer)
    context = described_class.for_tools(rows, viewer)
    expect(reads { expect(serialize(rows, ToolSerializer, checkout_context: context)).to eq(expected) }).to be_empty
  end

  it 'keeps tool lookup query counts constant as the catalog grows' do
    tool
    viewer
    small = reads { described_class.for_tools([tool], viewer) }.length
    rows = [tool] + create_list(:tool, 8, shop: shop)
    large = reads { described_class.for_tools(rows, viewer) }.length
    expect(large).to eq(small)
    expect(large).to be <= 4
  end

  it 'preserves checkout serialization and refreshes revoked note access in a new context' do
    checkout = create(:tool_checkout, member: viewer, tool: tool, approved_by: viewer)
    rows = [checkout]
    expected = serialize(rows, ToolCheckoutSerializer)
    context = described_class.for_checkouts(rows, viewer)
    expect(reads { expect(serialize(rows, ToolCheckoutSerializer, checkout_context: context)).to eq(expected) }).to be_empty
    expect(context.notes_visible?(tool)).to be_truthy
    checkout.set(revoked_at: Time.current)
    expect(described_class.for_checkouts(rows, viewer).notes_visible?(tool)).to be_falsey
  end

  it 'batches approver names and tolerates string IDs and removed assignments' do
    approver = CheckoutApprover.create!(member: viewer, shop_ids: [shop.id.to_s], tool_ids: [tool.id.to_s])
    approver.set(tool_ids: [tool.id.to_s, BSON::ObjectId.new.to_s])
    rows = [approver]
    expected = serialize(rows, CheckoutApproverSerializer)
    context = nil
    expect(reads { context = described_class.for_approvers(rows) }.length).to eq(3)
    expect(reads { expect(serialize(rows, CheckoutApproverSerializer, checkout_context: context)).to eq(expected) }).to be_empty
  end

  it 'keeps note access and approval eligibility distinct for expired approvers' do
    CheckoutApprover.create!(member: viewer, tool_ids: [tool.id.to_s])
    viewer.expirationTime = 1
    context = described_class.for_tools([tool], viewer)
    expect(context.notes_visible?(tool)).to eq(tool.notes_visible_to?(viewer))
    expect(context.can_approve?(tool)).to be_falsey
  end

  %w[admin board_member resource_manager member].each do |role|
    it "preserves notes and management fields for #{role}" do
      viewer.role = role
      viewer.resource_manager_shop_ids = [shop.id.to_s]
      options = { management_shop_ids: role == 'resource_manager' ? [shop.id.to_s] : [],
                  global_management: role.in?(%w[admin board_member]) }
      context = described_class.for_tools([tool], viewer)
      expect(context.notes_visible?(tool)).to eq(tool.notes_visible_to?(viewer))
      expect(serialize([tool], AdminToolSerializer, **options, checkout_context: context))
        .to eq(serialize([tool], AdminToolSerializer, **options))
    end
  end
  it 'batches explicit group scopes without per-row catalog queries' do
    group = ToolGroup.create!(shop: shop, name: 'Kit', included_tool_ids: [tool.id.to_s])
    rows = [viewer, create(:member, :current)].map { |member| CheckoutApprover.create!(member: member, tool_group_ids: [group.id.to_s]) }
    context = nil
    expect(reads { context = described_class.for_approvers(rows) }.length).to eq(4)
    expect(reads do
      serialized = serialize(rows, CheckoutApproverSerializer, checkout_context: context)
      expect(serialized.map { |row| row.deep_stringify_keys['toolGroups'].first['name'] }).to eq(['Kit', 'Kit'])
    end).to be_empty
  end

end
