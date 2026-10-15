class GoogleResourceSyncJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(resource_type, resource_id)
    klass = resource_type.to_s.constantize
    record = klass.find(resource_id)
    return unless record

    category = klass == Shop ? "CONFERENCE_ROOM" : "OTHER"
    Service::GoogleWorkspace.ensure_resource!(record, category)
    Service::GoogleWorkspace.ensure_label!(record)
  rescue StandardError => error
    Service::GoogleApiErrorReporter.sanitize_error!(error)
    Service::GoogleApiErrorReporter.report_if_permission_denied(
      error,
      operation: "google_resource_sync_job",
      resource_type: resource_type,
      resource_id: resource_id
    )
    Service::ErrorReporter.notify(error)
    Rails.logger.warn(
      "Google resource sync failed for #{resource_type}/#{resource_id}: " \
      "#{Service::GoogleApiErrorReporter.full_error_message(error)}"
    )
    raise
  end
end
