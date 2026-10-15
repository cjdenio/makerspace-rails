require 'rails_helper'
RSpec.describe FixTicketDelivery do
  let(:client) { double('Slack client') }
  let(:reporter) { build(:member, :current) }
  let(:ticket) { FixTicket.create!(reporter_id: reporter.id, title: 'Drill', description: 'Stopped', category: 'broken', submission_key: SecureRandom.uuid) }
  let(:event) { FixTicketEvent.create!(ticket_id: ticket.id, actor_id: reporter.id, kind: 'note', note: 'Switch <@USER> failed', revision: 1) }
  before do
    allow(Service::SlackConnector).to receive(:client).and_return(client)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('SLACK_TICKETS_CHANNEL').and_return('C1234567890')
    allow(ENV).to receive(:[]).with('SLACK_ENV').and_return('production')
    allow(ENV).to receive(:[]).with('SLACK_TEAM_ID').and_return('T_TEST')
    allow(ShortUrl).to receive(:base_url).and_return('https://portal.example.com')
  end
  it 'uses a saved channel override for new events and delivery' do
    allow(ENV).to receive(:[]).with('SLACK_TICKETS_CHANNEL').and_return(nil)
    SystemConfig.set('slack_channel_tickets', 'C9876543210')
    expect(event.central_enabled).to be(true)
    expect(client).to receive(:chat_postMessage).with(hash_including(channel: 'C9876543210', thread_ts: nil)).and_return({ 'ts' => '100.001', 'channel' => 'C9876543210' })
    expect(client).to receive(:chat_postMessage).with(hash_including(channel: 'C9876543210', thread_ts: '100.001')).and_return({ 'ts' => '100.002', 'channel' => 'C9876543210' })
    described_class.call(ticket, event)
  end
  [false, true].each do |fallback|
    it "delivers unscoped staff events with central disabled (RM default: #{fallback})" do
      SystemConfig.set('slack_channel_tickets', '')
      SystemConfig.set('slack_channel_rm', fallback ? '' : 'C1111111111')
      SystemConfig.set('slack_channel_admin', 'C2222222222')
      event.set(unscoped_staff_notification: true, central_enabled: false)
      destination = fallback ? 'C3333333333' : 'C1111111111'
      allow(Service::SlackConnector).to receive(:resolved_channel_id).with('resource_managers').and_return(destination) if fallback
      expect(client).to receive(:chat_postMessage).with(hash_including(channel: destination, text: include("Ticket ##{ticket.id}", 'Switch &lt;@USER&gt; failed'))).once.and_return('ts' => '100.001', 'channel' => destination)
      2.times { described_class.call(ticket, event) }
      expect(event.reload.delivered['unscoped-staff-0']['channel']).to eq(destination)
    end
  end
  it 'stops queued central delivery when a blank override disables the environment channel' do
    expect(event.central_enabled).to be(true)
    SystemConfig.set('slack_channel_tickets', '')
    expect(FixTicketEvent.new.central_enabled).to be(false)
    expect(client).not_to receive(:chat_postMessage)
    described_class.call(ticket, event)
    expect(event.reload.completed_at).to be_present
  end

  %w[shop_id tool_id].each do |field|
    it "announces #{field} changes to the current destination exactly once" do
      shop = create(:shop, slack_channel: 'C2222222222')
      tool = create(:tool, shop: shop, announce_channel: 'C3333333333') if field == 'tool_id'
      ticket.set(shop_id: shop.id, tool_id: tool&.id, announce_to_slack: true)
      event.set(kind: 'updated', note: nil, central_enabled: false,
        field_changes: { field => [BSON::ObjectId.new, tool&.id || shop.id] })
      destination = tool ? 'C3333333333' : 'C2222222222'
      expect(client).to receive(:chat_postMessage).with(hash_including(channel: destination, text: include("Ticket ##{ticket.id}", shop.name))).once.and_return('ts' => '100.001', 'channel' => destination)
      2.times { described_class.call(ticket.reload, event.reload) }
    end
  end

  it 'delivers reference changes when the new shop destination is also the central channel' do
    shop = create(:shop, slack_channel: 'C1234567890')
    ticket.set(shop_id: shop.id, announce_to_slack: true, slack_ticket_ts: '100.000',
      slack_ticket_channel_id: 'C1234567890', slack_ticket_team_id: 'T_TEST')
    event.set(kind: 'updated', note: nil, field_changes: { 'shop_id' => [nil, shop.id] })
    allow(client).to receive(:chat_getPermalink).and_return({})
    expect(client).to receive(:chat_postMessage).with(hash_including(channel: 'C1234567890', thread_ts: '100.000', text: include(shop.name))).once.and_return('ts' => '100.001', 'channel' => 'C1234567890')
    described_class.call(ticket.reload, event)
  end

  it 'skips a missing optional shop destination and still delivers recipient DMs' do
    allow(Service::MemberProvisioning).to receive(:invite_slack)
    reporter.save!
    ticket.set(announce_to_slack: true)
    SlackUser.create!(member_id: reporter.id, slack_id: 'U123')
    event.set(kind: 'updated', field_changes: { 'announce_to_slack' => [false, true] }, recipients: [reporter.id], central_enabled: false)
    allow(Service::SlackConnector).to receive(:safe_channel).with('U123').and_return('U123')
    expect(client).to receive(:chat_postMessage).with(hash_including(channel: 'U123')).and_return({ 'ts' => '100.002', 'channel' => 'D123' })
    described_class.call(ticket, event)
    expect(event.reload.completed_at).to be_present
  end

  %w[note bounty].each do |kind|
    it "reposts a previously delivered #{kind} into a replacement root" do
      ticket.set(slack_ticket_ts: '90.001', slack_ticket_channel_id: 'C1234567890', slack_ticket_team_id: 'T_TEST')
      receipt_key = kind == 'note' ? "central-#{Digest::SHA256.hexdigest('T_TEST/C1234567890/90.001')}-0" : 'central-0'
      event.set(kind: kind, delivered: { receipt_key => { 'ts' => '90.002', 'channel' => 'C1234567890' } },
        delivery_attempts: { receipt_key => { 'channel' => 'C1234567890', 'thread_ts' => '90.001', 'oldest' => '89' } }, delivery_error: 'IOError')
      allow(ShortUrl).to receive(:allocate).and_return(short_url: 'https://portal.example.com/L23456789AB')
      expect(client).to receive(:chat_getPermalink).and_raise(Slack::Web::Api::Errors::SlackError.new('message_not_found'))
      expect(client).to receive(:chat_postMessage).with(hash_including(thread_ts: nil)).ordered.and_return({ 'ts' => '101.001', 'channel' => 'C1234567890' })
      expect(client).to receive(:chat_postMessage).with(hash_including(thread_ts: '101.001', text: include('Switch &lt;@USER&gt; failed'), reply_broadcast: kind == 'bounty')).ordered.and_return({ 'ts' => '101.002', 'channel' => 'C1234567890' })
      described_class.call(ticket, event)
      expect(event.reload.completed_at).to be_present
      expect(event.delivered.values.map { |receipt| receipt['ts'] }).to include('101.002')
    end
  end

  it 'links delayed bounty announcements to their original task after replacement' do
    original_id = BSON::ObjectId.new
    ticket.set(bounty_id: BSON::ObjectId.new)
    event.set(kind: 'bounty', central_enabled: false, field_changes: { 'bounty_id' => [nil, original_id] })
    expect(ShortUrl).to receive(:allocate).with("/volunteer/tasks/#{original_id}", origin: 'https://portal.example.com').and_return(short_url: 'https://portal.example.com/L23456789AB')
    described_class.call(ticket, event)
  end

  it 'retains legacy receipts when the same root still exists' do
    ticket.set(slack_ticket_ts: '90.001', slack_ticket_channel_id: 'C1234567890', slack_ticket_team_id: 'T_TEST')
    event.set(delivered: { 'central-0' => { 'ts' => '90.002', 'channel' => 'C1234567890' } },
      delivery_attempts: { 'central-0' => { 'channel' => 'C1234567890', 'thread_ts' => '90.001', 'oldest' => '89' } })
    expect(client).to receive(:chat_getPermalink).and_return({})
    expect(client).not_to receive(:chat_postMessage)
    described_class.call(ticket, event)
    expect(event.reload.completed_at).to be_present
  end

  it 'creates a root then posts a full escaped note with its thread_ts' do
    expect(client).to receive(:chat_postMessage).with(hash_including(channel: 'C1234567890', thread_ts: nil, text: include("Ticket ##{ticket.id}:"))).ordered.and_return({ 'ts' => '100.001', 'channel' => 'C1234567890' })
    expect(client).to receive(:chat_postMessage).with(hash_including(thread_ts: '100.001', text: include("Ticket ##{ticket.id}:", 'Switch &lt;@USER&gt; failed'), reply_broadcast: false)).ordered.and_return({ 'ts' => '100.002', 'channel' => 'C1234567890' })
    described_class.call(ticket, event)
    expect(ticket.reload.slack_ticket_ts).to eq('100.001')
    expect(event.reload.completed_at).to be_present
  end
  it 'includes the ticket number in recipient DMs' do
    allow(Service::MemberProvisioning).to receive(:invite_slack)
    reporter.save!
    SlackUser.create!(member_id: reporter.id, slack_id: 'U123')
    event.set(recipients: [reporter.id], central_enabled: false)
    allow(Service::SlackConnector).to receive(:safe_channel).with('U123').and_return('U123')
    expect(client).to receive(:chat_postMessage).with(hash_including(channel: 'U123', text: include("Ticket ##{ticket.id}:"))).and_return({ 'ts' => '100.001', 'channel' => 'D123' })
    described_class.call(ticket, event)
  end
  %w[revoked suspended].each do |status|
    it "completes delivery without contacting a #{status} participant" do
      allow(Service::MemberProvisioning).to receive(:invite_slack)
      reporter.save!
      ticket.set(assignee_ids: [reporter.id])
      event.set(recipients: [reporter.id], central_enabled: false)
      reporter.set(status: status)
      expect(SlackUser).not_to receive(:where)
      expect(client).not_to receive(:chat_postMessage)
      described_class.call(ticket, event)
      expect(event.reload.completed_at).to be_present
    end
  end
  it 'redacts legacy assignment deltas and reporter attribution before Slack publication' do
    event.set(kind: 'assigned', note: nil, field_changes: { 'assignees' => [[reporter.fullname], []] })
    allow(client).to receive(:chat_postMessage).and_return({ 'ts' => '100.001', 'channel' => 'C1234567890' })
    described_class.call(ticket, event)
    expect(client).to have_received(:chat_postMessage).with(hash_including(thread_ts: '100.001', text: include('Member: assigned')))
    expect(client).not_to have_received(:chat_postMessage).with(hash_including(text: include(reporter.fullname)))
    expect(client).not_to have_received(:chat_postMessage).with(hash_including(text: include('Reporter: assigned')))
  end
  it 'replaces a deleted root and broadcasts a new bounty in its thread' do
    ticket.set(slack_ticket_ts: '90.001', slack_ticket_channel_id: 'C1234567890', slack_ticket_team_id: 'T_TEST', bounty_id: BSON::ObjectId.new)
    event.set(kind: 'bounty', note: nil)
    allow(ShortUrl).to receive(:allocate).and_return(short_url: 'https://portal.example.com/L23456789AB')
    expect(client).to receive(:chat_getPermalink).and_raise(Slack::Web::Api::Errors::SlackError.new('message_not_found'))
    expect(client).to receive(:chat_postMessage).with(hash_including(thread_ts: nil)).ordered.and_return({ 'ts' => '101.001', 'channel' => 'C1234567890' })
    expect(client).to receive(:chat_postMessage).with(hash_including(thread_ts: '101.001', reply_broadcast: true)).ordered.and_return({ 'ts' => '101.002', 'channel' => 'C1234567890' })
    described_class.call(ticket, event)
    expect(ticket.reload.slack_ticket_ts).to eq('101.001')
  end
  it 'does not recreate roots on access failures' do
    ticket.set(slack_ticket_ts: '90.001', slack_ticket_channel_id: 'C1234567890', slack_ticket_team_id: 'T_TEST')
    allow(client).to receive(:chat_getPermalink).and_raise(Slack::Web::Api::Errors::SlackError.new('access_denied'))
    expect(client).not_to receive(:chat_postMessage)
    expect { described_class.call(ticket, event) }.to raise_error(Slack::Web::Api::Errors::SlackError)
    expect(ticket.reload.slack_ticket_ts).to eq('90.001')
  end
  it 'reconciles an uncertain send before retrying it' do
    allow(client).to receive(:chat_postMessage).and_raise(Timeout::Error)
    expect { described_class.call(ticket, event) }.to raise_error(Timeout::Error)
    key = event.reload.delivery_attempts.keys.first
    digest = Digest::SHA256.hexdigest("#{event.id}/#{key}")
    uuid = [digest[0,8], digest[8,4], digest[12,4], digest[16,4], digest[20,12]].join('-')
    allow(client).to receive(:conversations_history).and_return({ 'messages' => [{ 'ts' => '100.001', 'client_msg_id' => uuid }] })
    expect(client).to receive(:chat_postMessage).with(hash_including(thread_ts: '100.001')).and_return({ 'ts' => '100.002', 'channel' => 'C1234567890' })
    described_class.call(ticket, event)
    expect(event.reload.completed_at).to be_present
  end
  it 'does not backfill central publication for events created while disabled' do
    event.set(central_enabled: false)
    expect(client).not_to receive(:chat_postMessage)
    described_class.call(ticket, event)
  end

  it 'does not publish unrelated updates or create a root for them' do
    event.set(kind: 'updated', note: nil, field_changes: { 'description' => ['old', 'Private repair details'], 'public_read_only' => [true, false] })
    expect(client).not_to receive(:chat_postMessage)
    expect(client).not_to receive(:chat_getPermalink)
    described_class.call(ticket, event)
    expect(ticket.reload.slack_ticket_ts).to be_nil
  end
  it 'includes approved activity but omits unrelated fields from mixed updates' do
    event.set(kind: 'updated', note: 'A new discussion note', field_changes: { 'status' => ['open', 'in_progress'], 'description' => ['old', 'Private repair details'], 'category' => ['broken', 'missing'] })
    allow(client).to receive(:chat_postMessage).and_return({ 'ts' => '100.001', 'channel' => 'C1234567890' })
    described_class.call(ticket, event)
    expect(client).to have_received(:chat_postMessage).with(hash_including(thread_ts: '100.001', text: include('in_progress', 'A new discussion note')))
    expect(client).not_to have_received(:chat_postMessage).with(hash_including(text: include('Private repair details')))
    expect(client).not_to have_received(:chat_postMessage).with(hash_including(text: include('category:')))
  end

end
