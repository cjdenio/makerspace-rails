namespace :slack do
  desc "Refresh the Redis cache of active public Slack channels.
        Run daily by the Heroku scheduler add-on; only does real work on the
        day of month configured via SystemConfig::CHANNEL_CACHE_REFRESH_DAY.
        Use the admin Jobs 'Run Now' button to run on demand regardless of day."
  task refresh_public_channel_cache: :environment do
    unless SystemConfig.scheduled_day_matches?(SystemConfig::CHANNEL_CACHE_REFRESH_DAY)
      puts "[Slack Channel Cache] Skipping -- not the configured day of month"
      next
    end

    count = SlackChannelCacheRefreshJob.perform_now
    puts "Cached #{count || 0} public Slack channels"
  end

  desc "Bulk sync Slack workspace users to SlackUser records, matching by email to Member accounts.
        Controlled via SystemConfig key 'slack_sync_enabled' — toggle from the admin settings UI.
        For on-demand single-user sync, use Service::SlackUserSync.sync_single(slack_id) directly."
  task sync_users: :environment do
    begin
      result = Service::SlackUserSync.sync_all
      next if result[:skipped]

      SystemConfig.record_run('slack_sync', success: true)
      ::Service::SlackConnector.send_slack_message(
        "✅ Slack user sync complete — Created: #{result[:created]}, Updated: #{result[:updated]}, Unmatched: #{result[:unmatched]}",
        ::Service::SlackConnector.logs_channel
      )
    rescue => e
      SystemConfig.record_run('slack_sync', success: false)
      ::Service::SlackConnector.send_slack_message(
        "❌ Slack user sync failed: #{e.message}",
        ::Service::SlackConnector.logs_channel
      )
      raise e
    end
  end
end
