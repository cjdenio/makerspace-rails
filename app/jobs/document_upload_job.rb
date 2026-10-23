class DocumentUploadJob < ApplicationJob
  include Service::SlackConnector
  include ::Service::GoogleDrive

  queue_as :slack

  # Active Job normally includes every argument in its automatic
  # "Performing" log entry. The first argument to this job is an entire
  # base64-encoded signature, so keep all arguments out of that entry and log
  # the useful, non-sensitive context ourselves in #perform.
  self.log_arguments = false

  # Fires only once retries are exhausted, for ANY StandardError -- not just
  # Error::Google::Upload. The narrower rescue this replaced meant an upload
  # to a misconfigured destination folder, a PDF-generation bug, or
  # any other failure type retried silently and then died with no alert and
  # no rollback: the resource stayed marked "signed" pointing at a document
  # that was never actually created.
  retry_on StandardError, attempts: 5 do |job, error|
    _base64_signature, document_type, resource_id = job.arguments
    job.send(:report_upload_failure, document_type, resource_id, error)
  end

  def perform(base64_signature, document_type, resource_id)
    resource, member, _on_fail = resolve_resource(document_type, resource_id)
    overloads = document_type == "rental_agreement" ? { rental: resource } : {}

    Rails.logger.info(
      "[DocumentUploadJob] Uploading document " \
      "resource=#{resource.class.name}(#{resource.id}) " \
      "member=#{member.fullname.inspect} document_type=#{document_type.inspect}"
    )

    document = if executions > 1 && ::Service::GoogleDrive.document_uploaded?(
      resource,
      document_type,
      upload_attempt_id: job_id
    )
      Rails.logger.info(
        "[DocumentUploadJob] Expected document already exists; skipping duplicate Drive upload " \
        "resource=#{resource.class.name}(#{resource.id}) document_type=#{document_type.inspect}"
      )
      # Read back the exact bytes already confirmed present, rather than
      # re-rendering from current model/clock state -- a fresh render here
      # isn't guaranteed to match what's archived (e.g. if the retry crosses
      # midnight, the signed-date in a re-rendered PDF would differ from the
      # one actually on file for this legal document).
      downloaded_file = ::Service::GoogleDrive.get_document(resource, document_type, upload_attempt_id: job_id)
      begin
        File.binread(downloaded_file.path)
      ensure
        # get_document hands back an open Tempfile -- this runs in a
        # long-lived queue worker, so leaving cleanup to GC would let
        # repeated retries accumulate temp files and file descriptors.
        downloaded_file.close!
      end
    else
      upload_document(
        document_type,
        member,
        overloads,
        base64_signature,
        upload_attempt_id: job_id
      )
    end
    verify_uploaded!(resource, document_type, upload_attempt_id: job_id)
    MemberMailer.send_document(document_type, member.id.as_json, document).deliver_later
  end

  private

  def resolve_resource(document_type, resource_id)
    case document_type
    when "member_contract"
      resource = Member.find(resource_id)
      [resource, resource, -> { resource.update_attributes!(member_contract_signed_date: nil) }]
    when "rental_agreement"
      resource = Rental.find(resource_id)
      [resource, resource.member, -> { resource.update_attributes!(contract_on_file: false) }]
    end
  end

  # An upload can report success without the file actually landing where
  # get_document will later look (e.g. a misconfigured destination folder).
  # Confirming it's really there turns that into a normal, detectable
  # failure instead of a silent one.
  def verify_uploaded!(resource, document_type, upload_attempt_id:)
    return if ::Service::GoogleDrive.document_uploaded?(
      resource,
      document_type,
      upload_attempt_id: upload_attempt_id
    )

    member = resource.kind_of?(Member) ? resource : resource.member
    expected_filename = ::Service::GoogleDrive.expected_document_filename(resource, document_type)
    folder_id = ::Service::GoogleDrive.get_templates().dig(document_type.to_sym, :folder_id)

    raise Error::Google::Upload.new(
      "Upload appeared to succeed but the file could not be found in Drive afterward " \
      "(member=#{member.fullname.inspect}, resource=#{resource.class.name}(#{resource.id}), " \
      "document_type=#{document_type.inspect}, expected_filename=#{expected_filename.inspect}, " \
      "folder_id=#{folder_id.inspect}, upload_attempt_id=#{upload_attempt_id.inspect})"
    )
  end

  # Alerts Slack, writes a durable audit log entry, and rolls back the
  # resource's "signed" state -- called once retries are exhausted for any
  # failure, whether raised by the upload itself or by verify_uploaded!.
  def report_upload_failure(document_type, resource_id, error)
    resource, member, on_fail = resolve_resource(document_type, resource_id)

    member_name = member&.fullname || "Unknown member (#{resource_id})"
    message = "Error uploading #{member_name}'s #{document_type} signature after all retries. " \
      "Error: #{error.class}: #{error.message}"

    ::Service::SlackConnector.send_slack_message(message)
    ::Service::AuditLogger.log(
      log_type:      'member',
      event_type:    'document_upload_failed',
      resource_type: document_type == 'member_contract' ? 'Member' : 'Rental',
      resource_id:   resource_id,
      subject:       member,
      message_details: message
    )
    on_fail&.call
  rescue => reporting_error
    # A bug here must never hide the original upload failure.
    Rails.logger.error("[DocumentUploadJob] failed to report upload failure: #{reporting_error}")
  end
end
