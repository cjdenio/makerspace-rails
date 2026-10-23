require 'rails_helper'

RSpec.describe AvailableShopCache do
  before do
    ActiveJob::Base.queue_adapter = :test
  end

  def cached_ids
    described_class.fetch.map(&:id)
  end

  it 'caches configured channel values without Slack resolution, including legacy blank and null values' do
    shops = [create(:shop, slack_channel: 'woodshop'), create(:shop, slack_channel: 'C12345678'),
      create(:shop, slack_channel: nil), create(:shop)]
    shops.last.set(slack_channel: '')
    expect(Service::SlackChannelCache).not_to receive(:lookup)
    described_class.refresh!
    expect(described_class.fetch.to_h { |entry| [entry.id, entry.slack_channel] }).to eq(
      shops[0].id.to_s => '#woodshop', shops[1].id.to_s => 'C12345678',
      shops[2].id.to_s => nil, shops[3].id.to_s => '')
  end

  it 'uses case-insensitive order on misses, hits, and full-list warming and includes out-of-service shops' do
    zebra = create(:shop, name: 'Zebra')
    wood = create(:shop, name: 'woodworking', out_of_service: true, out_of_service_note: 'Repair')
    hidden = create(:shop, name: 'Hidden', disabled: true)
    described_class.invalidate!
    expect(cached_ids).to eq([wood.id.to_s, zebra.id.to_s])
    expect(Shop).not_to receive(:where)
    expect(cached_ids).to eq([wood.id.to_s, zebra.id.to_s])
    expect(described_class.load_all.map(&:id)).to eq([hidden.id, wood.id, zebra.id])
    expect(cached_ids).to eq([wood.id.to_s, zebra.id.to_s])
  end

  it 'treats an empty cached list as a hit' do
    described_class.refresh!
    expect(Shop).not_to receive(:where)
    expect(described_class.fetch).to eq([])
  end

  it 'expires after 10,800 seconds without extending expiration on reads' do
    create(:shop)
    expect(described_class::TTL).to eq(10_800)
    expect(REDIS.ttl(described_class.data_key)).to be_between(10_798, 10_800)
    REDIS.expire(described_class.data_key, 30)
    described_class.fetch
    expect(REDIS.ttl(described_class.data_key)).to be <= 30
  end

  it 'refreshes creation, rename, hide/unhide, channel reassignment/removal and destruction' do
    shop = create(:shop, slack_channel: 'old')
    expect(cached_ids).to eq([shop.id.to_s])
    shop.update!(name: 'Renamed', slack_channel: 'new')
    expect(described_class.fetch.first.to_h).to include(name: 'Renamed', slack_channel: '#new')
    expect(described_class.find_by_channel(channel_name: 'old')).to be_nil
    expect(described_class.find_by_channel(channel_name: '#NEW').id).to eq(shop.id.to_s)
    shop.update!(slack_channel: nil)
    expect(described_class.find_by_channel(channel_name: 'new')).to be_nil
    shop.update!(disabled: true)
    expect(cached_ids).to be_empty
    shop.update!(disabled: false)
    expect(cached_ids).to eq([shop.id.to_s])
    shop.destroy!
    expect(cached_ids).to be_empty
  end

  it 'matches channel IDs and ignores hidden shops and unmatched channels' do
    shop = create(:shop, slack_channel: 'C12345678')
    create(:shop, slack_channel: 'hidden', disabled: true)
    expect(described_class.find_by_channel(channel_id: 'C12345678').id).to eq(shop.id.to_s)
    expect(described_class.find_by_channel(channel_name: 'hidden')).to be_nil
    expect(described_class.find_by_channel(channel_name: 'unknown')).to be_nil
  end

  it 'leaves the cache unchanged for failed validation and unrelated edits' do
    shop = create(:shop)
    previous = REDIS.get(described_class.data_key)
    expect(shop.update(name: '')).to be(false)
    shop.reload.update!(capacity: 20)
    expect(REDIS.get(described_class.data_key)).to eq(previous)
  end

  it 'does not refresh a deletion aborted by a supported destroy callback' do
    shop = create(:shop)
    callback = -> { throw :abort }
    Shop.set_callback(:destroy, :before, callback)
    begin
      expect(described_class).not_to receive(:refresh)
      expect(shop.destroy).to be(false)
      expect(cached_ids).to eq([shop.id.to_s])
    ensure
      Shop.skip_callback(:destroy, :before, callback)
    end
  end

  it 'refreshes before an integration callback fails after persistence' do
    shop = create(:shop)
    allow(shop).to receive(:warm_changed_slack_channel_cache).and_raise('integration unavailable')
    expect { shop.update!(name: 'Persisted') }.to raise_error('integration unavailable')
    expect(described_class.fetch.first.name).to eq('Persisted')
  end

  it 'falls back to MongoDB on Redis failure and allows successful edits' do
    shop = create(:shop)
    allow(REDIS).to receive(:get).and_raise(Redis::CannotConnectError)
    allow(REDIS).to receive(:eval).and_raise(Redis::CannotConnectError)
    expect { shop.update!(name: 'Still saved') }.not_to raise_error
    expect(described_class.fetch.first.name).to eq('Still saved')
    allow(REDIS).to receive(:get).and_call_original
    allow(REDIS).to receive(:eval).and_call_original
    shop.update!(name: 'Recovered')
    expect(described_class.fetch.first.name).to eq('Recovered')
  end

  it 'replaces malformed and expired snapshots' do
    shop = create(:shop)
    ['not json', '{}', { version: 1, started_at: Time.now.to_f - 10_801, entries: [] }.to_json,
      { version: 1, started_at: Time.now.to_f, entries: [{ id: 'bad' }] }.to_json].each do |raw|
      REDIS.set(described_class.data_key, raw)
      expect(cached_ids).to eq([shop.id.to_s])
    end
  end

  it 'rejects an older in-flight snapshot after a concurrent refresh' do
    shop = create(:shop, name: 'Before')
    token = REDIS.get(described_class.generation_key)
    started_at = Time.now.to_f
    old_entries = described_class.fetch
    shop.update!(name: 'After')
    expect(described_class.send(:publish, token, started_at, old_entries)).to be(false)
    expect(described_class.fetch.first.name).to eq('After')
    current_token = REDIS.get(described_class.generation_key)
    expect(described_class.send(:publish, current_token, Time.now.to_f - 10_801, old_entries)).to be(false)
  end

  it 'also fences older snapshots when a newer full-query warmer starts' do
    create(:shop)
    old_token = REDIS.get(described_class.generation_key)
    old_entries = described_class.fetch
    started_at = Time.now.to_f
    described_class.load_all
    expect(described_class.send(:publish, old_token, started_at, old_entries)).to be(false)
  end

  it 'does not warm from arbitrary restricted or projected queries' do
    shop = create(:shop)
    create(:shop)
    before = REDIS.get(described_class.data_key)
    Shop.where(id: shop.id).only(:name).limit(1).to_a
    expect(REDIS.get(described_class.data_key)).to eq(before)
    expect { described_class.load_visible(Shop.where(id: shop.id)) }.to raise_error(ArgumentError)
  end

  it 'keeps privileged hidden-shop choices live while ordinary choices use the cache' do
    visible = create(:shop)
    hidden = create(:shop, disabled: true)
    ordinary = build(:member, role: 'member')
    admin = build(:member, role: 'admin')
    manager = build(:member, role: 'resource_manager', resource_manager_shop_ids: [hidden.id.to_s])
    expect(FixTicketService.shop_choices(ordinary).map { |s| s.id.to_s }).to eq([visible.id.to_s])
    [admin, manager].each do |member|
      expect(FixTicketService.shop_choices(member).map(&:id)).to contain_exactly(visible.id, hidden.id)
    end
    expect(cached_ids).to eq([visible.id.to_s])
  end

  it 'refreshes callback-bypassing bulk changes even after a partially failed import' do
    shop = create(:shop)
    expect do
      described_class.with_bulk_changes do
        Shop.where(id: shop.id).update_all(name: 'Imported')
        raise 'import failed'
      end
    end.to raise_error('import failed')
    expect(described_class.fetch.first.name).to eq('Imported')
    described_class.with_bulk_changes { Shop.delete_all }
    expect(cached_ids).to be_empty
  end

  it 'isolates entries and generation tokens by effective database' do
    first = [described_class.data_key, described_class.generation_key]
    allow(Shop).to receive(:collection).and_return(double(database: double(name: 'makerspace_test_other')))
    second = [described_class.data_key, described_class.generation_key]
    expect(first & second).to be_empty
    expect(second).to all(include("v1:#{Rails.env}:makerspace_test_other:"))
  end
end
