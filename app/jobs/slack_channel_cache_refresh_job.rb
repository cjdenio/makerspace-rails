class SlackChannelCacheRefreshJob < ApplicationJob
  queue_as :default

  def perform
    count = Service::SlackChannelCache.rebuild!
    SystemConfig.record_run("slack_channel_cache", success: true)
    count
  rescue => error
    SystemConfig.record_run("slack_channel_cache", success: false)
    Service::ErrorReporter.notify(
      "SlackChannelCacheRefreshJob failed",
      context: { error: error.message }
    )
    raise error
  end
end
