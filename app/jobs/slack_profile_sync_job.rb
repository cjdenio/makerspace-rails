class SlackProfileSyncJob < ApplicationJob
  queue_as :default

  def perform
    begin
      Service::SlackProfileSync.sync_all
      SystemConfig.record_run("slack_profile_sync", success: true)
    rescue => e
      SystemConfig.record_run("slack_profile_sync", success: false)
      Honeybadger.notify("SlackProfileSyncJob failed", context: { error: e.message }) if defined?(Honeybadger)
      raise e
    end
  end
end
