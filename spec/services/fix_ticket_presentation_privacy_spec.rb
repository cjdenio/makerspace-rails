require 'rails_helper'

RSpec.describe 'Repair ticket presentation privacy' do
  let(:viewer) { create(:member, :current) }
  let(:admin) { create(:member, :current, :admin) }
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop, name: 'Private catalog tool', disabled: true, out_of_service: true) }
  let(:ticket) { create(:fix_ticket, reporter_id: admin.id, shop_id: shop.id, tool_id: tool.id, public_read_only: true) }
  before do
    allow(Service::MemberProvisioning).to receive(:invite_slack)
    allow(ShortUrl).to receive(:base_url).and_return('https://portal.example.com')
  end

  it 'redacts hidden catalog fields and history while retaining authorized staff metadata' do
    FixTicketEvent.create!(ticket_id: ticket.id, actor_id: admin.id, kind: 'updated', revision: 1, field_changes: { 'tool_id' => [nil, tool.id] })
    public_view = FixTicketPresenter.ticket(ticket, viewer, detail: true)
    expect(public_view).to include(toolId: nil, toolName: nil, toolHidden: false, outOfService: false)
    expect(public_view.to_json).not_to include(tool.id.to_s, tool.name)
    manager = create(:member, :current, :resource_manager, resource_manager_shop_ids: [shop.id.to_s])
    [admin, manager].each do |staff|
      expect(FixTicketPresenter.ticket(ticket, staff)).to include(toolId: tool.id.to_s, toolName: tool.name, toolHidden: true)
    end
    CheckoutApprover.create!(member_id: viewer.id, tool_ids: [tool.id.to_s])
    expect(FixTicketPolicy.new(viewer, ticket).staff?).to be_truthy
    expect(FixTicketPresenter.ticket(ticket, viewer)[:toolId]).to be_nil
    expect(FixSlack.detail(viewer, ticket.id)[:blocks].to_json).not_to include(tool.name, tool.id.to_s)
    expect(FixSlack.filters({ 'tool_id' => tool.id.to_s }, viewer).to_json).not_to include(tool.name)
  end

  it 'redacts later-hidden references and former hidden tools without hiding visible tools' do
    tool.set(disabled: false)
    expect(FixTicketPresenter.ticket(ticket, viewer)[:toolName]).to eq(tool.name)
    tool.set(disabled: true)
    visible = create(:tool, shop: shop)
    ticket.set(tool_id: visible.id)
    FixTicketEvent.create!(ticket_id: ticket.id, kind: 'updated', revision: 1, field_changes: { 'tool_id' => [tool.id, visible.id] })
    result = FixTicketPresenter.ticket(ticket, viewer, detail: true)
    expect(result[:toolId]).to eq(visible.id.to_s)
    expect(result[:events].first[:changes]['tool_id']).to eq([nil, visible.id])
    shop.set(disabled: true)
    result = FixTicketPresenter.ticket(ticket, viewer, detail: true)
    expect(result).to include(shopId: nil, shopName: nil, toolId: nil, toolName: nil)
  end

  it 'represents reporter assignees exactly like other assignees without linking assignment actions to Reporter' do
    ticket.set(assignee_ids: [admin.id, viewer.id])
    [admin, viewer].each_with_index do |actor, index|
      FixTicketEvent.create!(ticket_id: ticket.id, actor_id: actor.id, kind: 'assigned', revision: index + 1,
        field_changes: { 'assignees' => [[], [actor.fullname]] })
    end
    result = FixTicketPresenter.ticket(ticket, viewer, detail: true)
    expect(result[:assignees]).to eq([{ id: admin.id.to_s, name: admin.fullname }, { id: viewer.id.to_s, name: viewer.fullname }])
    expect(result[:events].map { |event| event[:actor] }).to eq(%w[Member Member])
    expect(result[:events].map { |event| event[:changes] }).to eq([{}, {}])
    expect(result.keys.grep(/reporter/i)).to be_empty
    slack = FixSlack.detail(viewer, ticket.id)[:blocks].to_json
    expect(slack).to include(admin.fullname, viewer.fullname)
    expect(slack).not_to include('Reporter')
  end
end
