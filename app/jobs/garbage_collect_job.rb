class GarbageCollectJob < ApplicationJob
  queue_as :default

  def perform
    last_month = Time.now - 30.days
    InvoiceHelper.clean_cache(last_month)
    ::Service::SlackConnector.send_slack_message(
      "Pruned Redis invoicing cache from last month.",
      ::Service::SlackConnector.logs_channel
    )
    SystemConfig.record_run("garbage_collect", success: true)
  rescue => e
    SystemConfig.record_run("garbage_collect", success: false)
    ::Service::SlackConnector.send_slack_message(
      "Error cleaning Redis: #{e.message}\n#{e.backtrace.inspect}",
      ::Service::SlackConnector.logs_channel
    )
    Service::ErrorReporter.notify("GarbageCollectJob failed", context: { error: e.message })
    raise e
  end
end
