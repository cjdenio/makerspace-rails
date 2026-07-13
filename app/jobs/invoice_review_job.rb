class InvoiceReviewJob < ApplicationJob
  queue_as :default

  def perform
    Rails.application.load_tasks
    begin
      Rake::Task["invoice_review"].reenable
      Rake::Task["invoice_review"].invoke
      SystemConfig.record_run("invoice_review", success: true)
    rescue => e
      SystemConfig.record_run("invoice_review", success: false)
      Honeybadger.notify("InvoiceReviewJob failed", context: { error: e.message })
      raise e
    end
  end
end
