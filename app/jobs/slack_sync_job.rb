class SlackSyncJob < ApplicationJob
  queue_as :default

  def perform
    Rails.application.load_tasks
    begin
      Rake::Task["slack:sync_users"].reenable
      Rake::Task["slack:sync_users"].invoke
      SystemConfig.record_run("slack_sync", success: true)
    rescue => e
      SystemConfig.record_run("slack_sync", success: false)
      Honeybadger.notify("SlackSyncJob failed", context: { error: e.message })
      raise e
    end
  end
end
