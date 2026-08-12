class ReservationSlackCanvasRebuildJob < ApplicationJob
  queue_as :default

  TASK_NAME = "reservations:rebuild_slack_canvases"

  def perform
    Rails.application.load_tasks unless Rake::Task.task_defined?(TASK_NAME)
    begin
      Rake::Task[TASK_NAME].reenable
      Rake::Task[TASK_NAME].invoke
      SystemConfig.record_run("reservation_canvas_rebuild", success: true)
    rescue => error
      SystemConfig.record_run("reservation_canvas_rebuild", success: false)
      Honeybadger.notify(
        "ReservationSlackCanvasRebuildJob failed",
        context: { error: error.message }
      )
      raise error
    end
  end
end
