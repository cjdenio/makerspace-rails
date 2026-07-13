desc "Clean up old invoicing redis keys"
task :gc => :environment do
  gc_error = nil

  begin
    last_month = Time.now - 30.days
    InvoiceHelper.clean_cache(last_month)
    slack_message = "Pruned Redis invoicing cache from last month."
  rescue => e
    gc_error = e
    error = "#{e.message}\n#{e.backtrace.inspect}"
    slack_message = "Error cleaning Redis: #{error}"
  end

  ::Service::SlackConnector.send_slack_message(slack_message, ::Service::SlackConnector.logs_channel)

  raise gc_error if gc_error
end
