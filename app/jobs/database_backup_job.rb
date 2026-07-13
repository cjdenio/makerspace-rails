class DatabaseBackupJob < ApplicationJob
  queue_as :default
  def perform
    Rails.application.load_tasks
    begin
      Rake::Task["backup"].reenable
      Rake::Task["backup"].invoke
      SystemConfig.record_run("db_backup", success: true)
    rescue => e
      SystemConfig.record_run("db_backup", success: false)
      Honeybadger.notify("DatabaseBackupJob failed", context: { error: e.message })
      raise e
    end
  end
end
