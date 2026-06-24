namespace :slack do
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
