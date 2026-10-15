require 'rails_helper'
RSpec.describe FixSlack do
  let(:member) { create(:member, :current) }
  before do
    allow(Service::MemberProvisioning).to receive(:invite_slack)
    ActiveJob::Base.queue_adapter = :test
    allow(ShortUrl).to receive(:base_url).and_return('https://portal.example.com')
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end
  it 'offers an unselected response role only for a reporter assignee' do
    ticket = create(:fix_ticket, reporter_id: member.id, assignee_ids: [member.id])
    block = described_class.note_role_inputs(member, { 'id' => ticket.id }).first
    expect(block[:element]).to include(type: 'radio_buttons')
    expect(block[:element]).not_to have_key(:initial_option)
    expect(block[:optional]).to be(false)
    ticket.set(assignee_ids: [])
    expect(described_class.note_role_inputs(member, { 'id' => ticket.id })).to be_empty
  end
  it 'uses searchable tool selections and a private submission key' do
    view = described_class.command_view(member, 'new')
    tool = view[:blocks].find { |block| block[:block_id] == 'tool_id' }
    expect(tool[:element][:type]).to eq('external_select')
    expect(JSON.parse(view[:private_metadata])['submission_key']).to be_present
  end
  it 'renders each scoped paginated list and complete filter controls' do
    %w[mine assigned queue public].each do |mode|
      view = described_class.command_view(member, mode)
      expect(JSON.parse(view[:private_metadata])['page_size']).to eq(10)
    end
    filter_ids = described_class.filters({}, member)[:blocks].map { |block| block[:block_id] }
    expect(filter_ids).to include('shop_id', 'priority', 'statuses', 'category', 'confirmation', 'tool_id', 'assignee_id')
  end
  it 'rejects a workspace mismatch before resolving identity' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('SLACK_TEAM_ID').and_return('T_EXPECTED')
    expect { described_class.member!({ 'team_id' => 'T_OTHER', 'user_id' => 'U_OTHER' }) }.to raise_error(Error::Forbidden)
  end
  it 'prefills the channel shop and keeps it as the list and new-report filter' do
    shop = create(:shop, slack_channel: 'woodshop')
    expect(described_class.channel_shop(member, { 'channel_id' => 'C123', 'channel_name' => 'woodshop' })).to eq(shop)
    shop.set(slack_channel: 'C123')
    expect(described_class.channel_shop(member, { 'channel_id' => 'C123' })).to eq(shop)
    expect(described_class.channel_shop(member, { 'channel_id' => 'C_OTHER' })).to be_nil
    view = described_class.command_view(member, 'new', shop: shop)
    expect(view[:blocks].find { |b| b[:block_id] == 'shop_id' }[:element][:initial_option][:value]).to eq(shop.id.to_s)
    expect(JSON.parse(view[:private_metadata]).dig('query', 'shop_id')).to eq(shop.id.to_s)
    expect(view[:blocks].select { |b| b[:type] == 'input' }).to all(include(:label, :hint))
    list = described_class.command_view(member, '', shop: shop)
    expect(JSON.parse(list[:private_metadata])).to include('shop_id' => shop.id.to_s, 'mode' => 'all')
  end

  it 'shows all readable open tickets privately, with optional channel shop scope' do
    shop = create(:shop, name: 'Woodworking')
    tool = create(:tool, shop: shop)
    outsider = create(:member, :current)
    CheckoutApprover.create!(member_id: member.id, tool_ids: [tool.id.to_s])
    own = create(:fix_ticket, reporter_id: member.id, shop_id: shop.id)
    public_ticket = create(:fix_ticket, reporter_id: outsider.id, public_read_only: true)
    scoped = create(:fix_ticket, reporter_id: outsider.id, tool_id: tool.id, shop_id: shop.id)
    create(:fix_ticket, reporter_id: outsider.id)
    create(:fix_ticket, reporter_id: member.id, status: 'resolved')
    result = described_class.command_view(member, 'show')
    expect(result[:response_type]).to eq('ephemeral')
    ids = result[:blocks].flat_map { |b| Array(b[:elements]) }.select { |e| e[:action_id] == 'fix_view' }.map { |e| JSON.parse(e[:value])['id'] }
    expect(ids).to contain_exactly(own.id.to_s, public_ticket.id.to_s, scoped.id.to_s)
    expect(result[:blocks].to_json).to include("##{own.id}:")
    local = described_class.command_view(member, 'show', shop: shop)
    expect(local[:text]).to start_with('Tickets in Woodworking:')
    expect(local[:blocks].to_json).not_to include("##{public_ticket.id}:")
    detail = described_class.command_view(member, "##{own.id}")
    expect(detail[:blocks].to_json).to include("##{own.id}:", "/fix-tickets/#{own.id}")
  end

  it 'paginates private show results and rechecks access for subsequent pages' do
    create_list(:fix_ticket, 11, reporter_id: member.id)
    result = described_class.command_view(member, 'show')
    next_button = result[:blocks].last[:elements].find { |e| e[:text][:text] == 'Next' }
    expect(next_button[:action_id]).to eq('fix_show_page')
    client = double('Slack')
    allow(Service::SlackConnector).to receive(:client).and_return(client)
    allow(described_class).to receive(:member!).and_return(member)
    expect(client).to receive(:chat_postEphemeral).with(hash_including(channel: 'C123', user: 'U123', text: include('page 2')))
    described_class.interaction({ 'type' => 'block_actions', 'channel' => { 'id' => 'C123' }, 'user' => { 'id' => 'U123' }, 'actions' => [{ 'action_id' => 'fix_show_page', 'value' => next_button[:value] }] })
  end
  it 'opens a detail modal from a private message button' do
    ticket = create(:fix_ticket, reporter_id: member.id)
    allow(described_class).to receive(:member!).and_return(member)
    expect(Service::SlackConnector).to receive(:open_modal).with('trigger', hash_including(callback_id: 'fix_detail'))
    described_class.interaction({ 'type' => 'block_actions', 'trigger_id' => 'trigger', 'actions' => [{ 'action_id' => 'fix_view', 'value' => { id: ticket.id.to_s }.to_json }] })
  end
  it 'limits assignee filter suggestions to visible ticket participants, including expired assignees' do
    visible = create(:member, :current, firstname: 'Visible')
    expired = create(:member, :expired, firstname: 'Former')
    outsider = create(:member, :current, firstname: 'Unrelated')
    create(:fix_ticket, reporter_id: member.id, assignee_ids: [visible.id, expired.id])
    create(:fix_ticket, reporter_id: outsider.id, assignee_ids: [outsider.id])
    payload = { 'action_id' => 'fix_search_assignee_id', 'value' => '' }
    expect(described_class.options(member, payload)[:options].map { |o| o[:value] }).to contain_exactly(visible.id.to_s, expired.id.to_s)
    expect(described_class.options(member, payload.merge('value' => 'Unrelated'))[:options]).to be_empty
    expect(described_class.options(member, payload.merge('value' => 'Vis'))[:options].map { |o| o[:value] }).to eq([visible.id.to_s])
  end
  it 'initializes tool and assignee filters without losing their IDs' do
    tool = create(:tool, shop: create(:shop))
    query = { 'tool_id' => tool.id.to_s, 'assignee_id' => member.id.to_s }
    view = described_class.filters(query, member)
    %w[tool_id assignee_id].each do |key|
      element = view[:blocks].find { |block| block[:block_id] == key }[:element]
      expect(element[:initial_option][:value]).to eq(query[key])
    end
    expect(JSON.parse(view[:private_metadata])).to include(query)
  end
  it 'clears a shop through the edit modal No shop choice', requires_transactions: true do
    admin = create(:member, :admin, :current)
    ticket = FixTicketService.create!(actor: member, attributes: { title: 'Repair', description: 'Broken', category: 'broken', shop_id: create(:shop).id.to_s, submission_key: SecureRandom.uuid })
    allow(described_class).to receive(:member!).and_return(admin)
    result = described_class.interaction({ 'type' => 'view_submission', 'view' => {
      'callback_id' => 'fix_edit', 'private_metadata' => { id: ticket.id.to_s }.to_json,
      'state' => { 'values' => { 'shop_id' => { 'fix_search_shop_id' => { 'selected_option' => { 'value' => 'none' } } } } }
    } })
    expect(result[:response_action]).to eq('update')
    expect(ticket.reload.shop_id).to be_nil
  end

end
