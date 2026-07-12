class DocumentUploadJob < ApplicationJob
  include Service::SlackConnector
  include ::Service::GoogleDrive
  retry_on StandardError

  queue_as :slack

  def perform(base64_signature, document_type, resource_id)
    if document_type == "member_contract"
      resource = Member.find(resource_id)
      member   = resource
      overloads = {}
      on_fail = -> { resource.update_attributes!(member_contract_signed_date: nil) }

    elsif document_type == "rental_agreement"
      resource = Rental.find(resource_id)
      member   = resource.member
      overloads = { rental: resource }
      on_fail = -> { resource.update_attributes!(contract_on_file: false) }
    end

    begin
      document = upload_document(document_type, member, overloads, base64_signature)
      MemberMailer.send_document(document_type, member.id.as_json, document).deliver_later
    rescue Error::Google::Upload => err
      member_name = member&.fullname || "Unknown member (#{resource_id})"
      ::Service::SlackConnector.send_slack_message("Error uploading #{member_name}'s #{document_type} signature. Error: #{err}")
      on_fail&.call
    end
  end
end
