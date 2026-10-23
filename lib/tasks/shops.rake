namespace :shops do
  desc 'Refresh the Redis list of non-hidden shop names and configured Slack channels'
  task refresh_cache: :environment do
    entries = AvailableShopCache.refresh!
    puts "Cached #{entries.length} available shops for #{AvailableShopCache::TTL} seconds."
  end
end
