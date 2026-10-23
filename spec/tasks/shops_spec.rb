require 'rails_helper'
require 'rake'

RSpec.describe 'shops:refresh_cache' do
  let(:task) { Rake::Task['shops:refresh_cache'] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('shops:refresh_cache')
    task.reenable
  end

  it 'warms the list after out-of-band changes' do
    shop = create(:shop)
    Shop.where(id: shop.id).update_all(name: 'Restored')
    expect { task.invoke }.to output(/Cached 1 available shops for 10800 seconds/).to_stdout
    expect(AvailableShopCache.fetch.first.name).to eq('Restored')
  end

  it 'fails visibly rather than reporting success when Redis is unavailable' do
    allow(REDIS).to receive(:eval).and_raise(Redis::CannotConnectError)
    expect { task.invoke }.to raise_error(Redis::CannotConnectError)
  end
end
