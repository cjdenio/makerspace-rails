class SlackProfileSyncJob < ApplicationJob
  queue_as :default

  def perform
    begin
      Service::SlackProfileSync.sync_all
      SystemConfig.record_run("slack_profile_sync", success: true)
    rescue => e
      SystemConfig.record_run("slack_profile_sync", success: false)
      Service::ErrorReporter.notify("SlackProfileSyncJob failed", context: { error: e.message })
      raise e
    end
  end
end
