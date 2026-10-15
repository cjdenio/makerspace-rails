require 'rails_helper'

RSpec.describe ShopAvailabilityService do
  let(:shop) { create(:shop, reservable: true) }
  let(:actor) { create(:member, :admin, :current) }
  before do
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end

  it 'requires a nonblank reason and a boolean without changing availability' do
    [nil, '', '  '].each do |note|
      expect { described_class.set!(shop: shop, actor: actor, value: true, note: note) }.to raise_error(Error::UnprocessableEntity)
    end
    expect { described_class.set!(shop: shop, actor: actor, value: 'true', note: 'Leak') }.to raise_error(Error::UnprocessableEntity)
    expect(shop.reload.out_of_service).to be(false)
  end

  it 'allows admin, board and assigned RM, but not members or other RMs' do
    [actor, create(:member, :board_member, :current), create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])].each do |person|
      described_class.set!(shop: shop, actor: person, value: true, note: 'Water leak')
      expect(shop.reload.out_of_service).to be(true)
      described_class.set!(shop: shop, actor: person, value: false)
    end
    [create(:member, :current), create(:member, :resource_manager, :current)].each do |person|
      expect { described_class.set!(shop: shop, actor: person, value: true, note: 'Leak') }.to raise_error(Error::Forbidden)
      expect { described_class.set!(shop: shop, actor: person, value: false) }.to raise_error(Error::Forbidden)
    end
  end

  it 'persists the reason and queues Slack only when a channel exists' do
    expect { described_class.set!(shop: shop, actor: actor, value: true, note: '  Water leak  ') }.not_to have_enqueued_job(ShopOutageSlackJob)
    expect(shop.reload.out_of_service_note).to eq('Water leak')
    described_class.set!(shop: shop, actor: actor, value: false)
    shop.set(slack_channel: '#woodshop')
    expect { described_class.set!(shop: shop, actor: actor, value: true, note: 'Leak') }.to have_enqueued_job(ShopOutageSlackJob)
      .with(shop.id.to_s, kind_of(String), '#woodshop', shop.name, 'Leak')
  end

  it 'blocks shop and tool reservations across sources, including board overrides' do
    person = create(:member, :board_member, :current)
    tool = create(:tool, shop: shop, reservable: true)
    start_at = 2.days.from_now.change(hour: 10, min: 0, sec: 0)
    described_class.set!(shop: shop, actor: actor, value: true, note: 'Leak')
    %w[shop tools].each do |scope|
      attrs = { title: 'Booking', shop_id: shop.id.to_s, reservation_scope: scope,
        tool_ids: scope == 'tools' ? [tool.id.to_s] : [], start_at: start_at.iso8601, end_at: (start_at + 1.hour).iso8601 }
      expect(ReservationService.preview(member: person, attributes: attrs)[:errors]).to include('The selected shop is out of service and cannot be reserved')
      %w[portal slack admin].each do |source|
        expect { ReservationService.create!(member: person, attributes: attrs, source: source) }.to raise_error(Error::UnprocessableEntity, /shop is out of service/)
      end
      described_class.set!(shop: shop, actor: actor, value: false)
      expect(ReservationService.preview(member: person, attributes: attrs)[:errors]).not_to include('The selected shop is out of service and cannot be reserved')
      described_class.set!(shop: shop, actor: actor, value: true, note: 'Leak')
    end
    expect(tool.reload.out_of_service).to be(false)
  end

  it 'preserves existing bookings and disables workshop reservation actions' do
    booking = create(:reservation, member: actor, shop: shop, reservation_scope: 'shop', tool_ids: [], start_at: 3.days.from_now, end_at: 3.days.from_now + 1.hour)
    tool = create(:tool, shop: shop, reservable: true, open: true)
    described_class.set!(shop: shop, actor: actor, value: true, note: 'Leak')
    expect(booking.reload.status).to eq('approved')
    serializer = WorkshopSerializer.new(shop.reload, scope: actor)
    expect(serializer.reservations_available).to be(false)
    expect(serializer.tools.find { |entry| entry[:id] == tool.id.to_s }[:reservationAvailable]).to be(false)
  end

  it 'refreshes both reservation canvases when setting and clearing the shop flag' do
    shop.set(slack_channel: '#woodshop')
    travel_to(ReservationService::ZONE.local(2026, 9, 15, 23, 30)) do
      [true, false].each do |value|
        expect { described_class.set!(shop: shop, actor: actor, value: value, note: 'Leak') }
          .to have_enqueued_job(ReservationSlackCanvasSyncJob).with(shop.id.to_s, %w[2026-09-15 2026-09-16])
      end
    end
  end

  it 'retries Slack failure without reopening the shop or inventing a receipt' do
    shop.set(out_of_service: true, out_of_service_note: 'Leak', outage_id: 'outage-1')
    allow(Service::SlackConnector).to receive(:resolved_channel_id).and_return('C123456789')
    client = double('Slack')
    allow(Service::SlackConnector).to receive(:client).and_return(client)
    allow(client).to receive(:chat_postMessage).and_raise(StandardError, 'Slack unavailable')
    expect { ShopOutageSlackJob.perform_now(shop.id.to_s, 'outage-1', '#woodshop', shop.name, 'Leak') }.to have_enqueued_job(ShopOutageSlackJob)
    expect(shop.reload.out_of_service).to be(true)
    expect(shop.ts_oos).to be_nil
  end

  it 'stores the Slack receipt and makes repeated jobs a no-op' do
    shop.set(out_of_service: true, out_of_service_note: 'Leak', outage_id: 'outage-1')
    client = double('Slack')
    allow(Service::SlackConnector).to receive(:client).and_return(client)
    allow(Service::SlackConnector).to receive(:resolved_channel_id).with('#woodshop').and_return('C123456789')
    expect(client).to receive(:chat_postMessage).with(hash_including(channel: 'C123456789', client_msg_id: 'outage-1', text: /Reason: Leak/)).once.and_return('ts' => '123.456')
    2.times { ShopOutageSlackJob.perform_now(shop.id.to_s, 'outage-1', '#woodshop', shop.name, 'Leak') }
    expect(shop.reload.ts_oos).to eq('123.456')
    ShopOutageSlackJob.perform_now(shop.id.to_s, 'old-outage', '#woodshop', shop.name, 'Old')
    expect(shop.reload.ts_oos).to eq('123.456')
  end

  it 'clears the shop flag without clearing a tool flag and broadcasts a reply only once' do
    tool = create(:tool, shop: shop, out_of_service: true)
    shop.set(out_of_service: true, out_of_service_note: 'Leak', outage_id: 'outage-1', ts_oos: '123.456', oos_channel_id: 'C123456789')
    expect { described_class.set!(shop: shop, actor: actor, value: false) }.to have_enqueued_job(ShopOutageSlackJob)
    expect(shop.reload.out_of_service).to be(false)
    expect(tool.reload.out_of_service).to be(true)
    client = double('Slack')
    allow(Service::SlackConnector).to receive(:client).and_return(client)
    expect(client).to receive(:chat_postMessage).with(hash_including(channel: 'C123456789', thread_ts: '123.456', reply_broadcast: true, text: /back in service/)).once.and_return('ts' => '123.789')
    2.times { ShopOutageSlackJob.perform_now(shop.id.to_s, 'outage-1', '#changed-channel', shop.name, 'Leak') }
    expect(shop.reload.ts_in_service).to eq('123.789')
    expect(shop.ts_oos).to eq('123.456')
  end

  it 'DMs each linked shop manager with actor, shop and note even without a shop channel' do
    managers = 2.times.map { create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s]) }
    managers.each_with_index { |manager, i| SlackUser.create!(member: manager, slack_id: "U00000000#{i}") }
    other = create(:member, :resource_manager, :current)
    SlackUser.create!(member: other, slack_id: 'U999999999')
    described_class.set!(shop: shop, actor: actor, value: true, note: 'Water leak')
    expect(shop.outage_manager_member_ids).to match_array(managers.map { |manager| manager.id.to_s })
    client = double('Slack')
    allow(Service::SlackConnector).to receive(:client).and_return(client)
    2.times do |i|
      expect(client).to receive(:conversations_open).with(users: "U00000000#{i}").once.and_return('channel' => { 'id' => "D#{i}" })
      expect(client).to receive(:chat_postMessage).with(hash_including(channel: "D#{i}", text: include(actor.fullname, shop.name, 'Water leak'))).once.and_return('ts' => "123.#{i}")
    end
    2.times { ShopOutageSlackJob.perform_now(shop.id.to_s, shop.outage_id, nil, shop.name, 'Water leak') }
    expect(shop.reload.outage_dm_receipts.size).to eq(2)
  end

  it 'delivers a restoration reply when cleared before the original announcement runs' do
    manager = create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
    SlackUser.create!(member: manager, slack_id: 'UMANAGER')
    shop.set(slack_channel: '#woodshop')
    described_class.set!(shop: shop, actor: actor, value: true, note: 'Leak')
    described_class.set!(shop: shop, actor: actor, value: false)
    client = double('Slack')
    allow(Service::SlackConnector).to receive(:client).and_return(client)
    expect(client).not_to receive(:conversations_open)
    allow(Service::SlackConnector).to receive(:resolved_channel_id).and_return('C123456789')
    expect(client).to receive(:chat_postMessage).with(hash_including(client_msg_id: shop.outage_id)).ordered.and_return('ts' => '123.1', 'channel' => 'C123456789')
    expect(client).to receive(:chat_postMessage).with(hash_including(thread_ts: '123.1', reply_broadcast: true)).ordered.and_return('ts' => '123.2')
    ShopOutageSlackJob.perform_now(shop.id.to_s, shop.outage_id, shop.slack_channel, shop.name, 'Leak')
    expect(shop.reload.ts_in_service).to eq('123.2')
  end

  %w[suspended revoked unassigned deleted unlinked].each do |change|
    it "rechecks a queued DM recipient who becomes #{change}" do
      manager = create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
      slack = SlackUser.create!(member: manager, slack_id: 'UMANAGER')
      described_class.set!(shop: shop, actor: actor, value: true, note: 'Internal reason')
      case change
      when 'unassigned' then manager.set(resource_manager_shop_ids: [])
      when 'deleted' then Member.where(id: manager.id).delete_all
      when 'unlinked' then slack.destroy!
      else manager.set(status: change)
      end
      client = double('Slack')
      allow(Service::SlackConnector).to receive(:client).and_return(client)
      expect(client).not_to receive(:conversations_open)
      expect(client).not_to receive(:chat_postMessage)
      ShopOutageSlackJob.perform_now(shop.id.to_s, shop.outage_id, nil, shop.name, 'Internal reason')
      expect(shop.reload.outage_dm_receipts).to be_empty
    end
  end

  it 'excludes already suppressed managers and rechecks after opening a DM' do
    suppressed = create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
    suppressed.set(status: 'suspended')
    manager = create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
    SlackUser.create!(member: manager, slack_id: 'UMANAGER')
    described_class.set!(shop: shop, actor: actor, value: true, note: 'Internal reason')
    expect(shop.outage_manager_member_ids).not_to include(suppressed.id.to_s)
    client = double('Slack')
    allow(Service::SlackConnector).to receive(:client).and_return(client)
    expect(client).to receive(:conversations_open).with(users: 'UMANAGER') do
      manager.set(status: 'revoked')
      { 'channel' => { 'id' => 'DMANAGER' } }
    end
    expect(client).not_to receive(:chat_postMessage)
    ShopOutageSlackJob.perform_now(shop.id.to_s, shop.outage_id, nil, shop.name, 'Internal reason')
  end

  it 'continues other DMs on failure and retries only unfinished recipients' do
    managers = 2.times.map { create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s]) }
    managers.each_with_index { |manager, i| SlackUser.create!(member: manager, slack_id: "U00000000#{i}") }
    shop.set(out_of_service: true, out_of_service_note: 'Leak', outage_id: 'outage-1', outage_actor_name: actor.fullname,
      outage_manager_member_ids: managers.map { |manager| manager.id.to_s })
    client = double('Slack')
    allow(Service::SlackConnector).to receive(:client).and_return(client)
    allow(client).to receive(:conversations_open).with(users: 'U000000000').and_return('channel' => { 'id' => 'D0' })
    expect(client).to receive(:conversations_open).with(users: 'U000000001').once.and_return('channel' => { 'id' => 'D1' })
    allow(client).to receive(:chat_postMessage).with(hash_including(channel: 'D0')).and_raise('DM temporarily unavailable')
    expect(client).to receive(:chat_postMessage).with(hash_including(channel: 'D1')).once.and_return('ts' => '123.1')
    expect { ShopOutageSlackJob.perform_now(shop.id.to_s, shop.outage_id, nil, shop.name, 'Leak') }.to have_enqueued_job(ShopOutageSlackJob)
    expect(shop.reload.outage_dm_receipts).to eq(managers.last.id.to_s => '123.1')
    allow(client).to receive(:chat_postMessage).with(hash_including(channel: 'D0')).and_return('ts' => '123.0')
    ShopOutageSlackJob.perform_now(shop.id.to_s, shop.outage_id, nil, shop.name, 'Leak')
    expect(shop.reload.outage_dm_receipts.size).to eq(2)
  end
end
