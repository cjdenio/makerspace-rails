class GarbageCollectJob < ApplicationJob
  queue_as :default

  def perform
    Rails.application.load_tasks
    begin
      Rake::Task["gc"].reenable
      Rake::Task["gc"].invoke
      SystemConfig.record_run("garbage_collect", success: true)
    rescue => e
      SystemConfig.record_run("garbage_collect", success: false)
      Honeybadger.notify("GarbageCollectJob failed", context: { error: e.message })
      raise e
    end
  end
end
