require 'rails_helper'
require 'rake'

RSpec.describe 'day-of-month guarded scheduled jobs' do
  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('gc')
  end

  describe 'gc' do
    let(:task) { Rake::Task['gc'] }

    before { task.reenable }
    after  { task.reenable }

    it 'skips on a day other than the configured one' do
      SystemConfig.set(SystemConfig::GARBAGE_COLLECT_DAY, '15')
      allow(GarbageCollectJob).to receive(:perform_now)

      travel_to(Time.zone.local(2026, 9, 1)) { task.invoke }

      expect(GarbageCollectJob).not_to have_received(:perform_now)
    end

    it 'runs on the configured day' do
      SystemConfig.set(SystemConfig::GARBAGE_COLLECT_DAY, '15')
      allow(GarbageCollectJob).to receive(:perform_now)

      travel_to(Time.zone.local(2026, 9, 15)) { task.invoke }

      expect(GarbageCollectJob).to have_received(:perform_now).at_least(:once)
    end
  end

  describe 'card_expiration_check' do
    let(:task) { Rake::Task['card_expiration_check'] }

    before { task.reenable }
    after  { task.reenable }

    it 'skips on a day other than the configured one' do
      SystemConfig.set(SystemConfig::CARD_EXPIRATION_CHECK_DAY, '1')
      allow(CardExpirationCheckJob).to receive(:perform_now)

      travel_to(Time.zone.local(2026, 9, 2)) { task.invoke }

      expect(CardExpirationCheckJob).not_to have_received(:perform_now)
    end

    it 'runs on the configured day' do
      SystemConfig.set(SystemConfig::CARD_EXPIRATION_CHECK_DAY, '1')
      allow(CardExpirationCheckJob).to receive(:perform_now)

      travel_to(Time.zone.local(2026, 9, 1)) { task.invoke }

      expect(CardExpirationCheckJob).to have_received(:perform_now).at_least(:once)
    end
  end

  describe 'slack:refresh_public_channel_cache' do
    let(:task) { Rake::Task['slack:refresh_public_channel_cache'] }

    before { task.reenable }
    after  { task.reenable }

    it 'skips on a day other than the configured one' do
      SystemConfig.set(SystemConfig::CHANNEL_CACHE_REFRESH_DAY, '1')
      allow(SlackChannelCacheRefreshJob).to receive(:perform_now)

      travel_to(Time.zone.local(2026, 9, 2)) { task.invoke }

      expect(SlackChannelCacheRefreshJob).not_to have_received(:perform_now)
    end

    it 'runs on the configured day' do
      SystemConfig.set(SystemConfig::CHANNEL_CACHE_REFRESH_DAY, '1')
      allow(SlackChannelCacheRefreshJob).to receive(:perform_now)

      travel_to(Time.zone.local(2026, 9, 1)) { task.invoke }

      expect(SlackChannelCacheRefreshJob).to have_received(:perform_now).at_least(:once)
    end
  end
end
