require 'base64'

module Service
  module GoogleDrive
    BASE64_SIGNATURE_PATTERN = /\A[A-Za-z0-9+\/]*={0,2}\z/.freeze
    DOCUMENT_UPLOAD_ATTEMPT_PROPERTY = 'document_upload_job_id'.freeze

    def self.build_template_location(document)
      Rails.root.join("app/views/documents/#{document}.html.erb")
    end

    def self.get_folder_id(id)
      Rails.env.production? ? id : ENV['SIGNATURES_FOLDER']
    end

    def self.get_templates()
      {
        member_contract: {
          folder_id: get_folder_id(ENV['MEMBER_CONTRACT_FOLDER']),
          file_id: ENV["CONTRACT_ID"],
          template_location: build_template_location("member_contract")
        },
        code_of_conduct: {
          folder_id: get_folder_id(ENV['CODE_CONDUCT_FOLDER']),
          file_id: ENV["CODE_CONDUCT_ID"],
          template_location: build_template_location("code_of_conduct")
        },
        rental_agreement: {
          folder_id: get_folder_id(ENV['RENTAL_AGREEMENT_FOLDER']),
          file_id: ENV["RENTAL_AGREEMENT_ID"],
          template_location: build_template_location("rental_agreement")
        },
      }
    end

    def load_gdrive
      ::Service::GoogleDrive.load_gdrive
    end

    def self.load_gdrive
      google = Google::Apis::DriveV3::DriveService.new
      google.authorization = Google::Auth::UserRefreshCredentials.new({
        client_id: ENV['GOOGLE_ID'],
        client_secret: ENV['GOOGLE_SECRET'],
        refresh_token: ENV['GOOGLE_TOKEN'],
        scope: ["https://www.googleapis.com/auth/drive"]
      })
      google
    end

    def invite_gdrive(email_address)
      unless ENV['GDRIVE_INVITES_ENABLED'] == 'true'
        raise Error::NotAllowed.new('Google Drive invites are not enabled in this environment')
      end
      permission = Google::Apis::DriveV3::Permission.new(type: :user,
          email_address: email_address,
          role: :reader)
      load_gdrive.create_permission(ENV['RESOURCES_FOLDER'], permission) do |result, err|
        report_google_error(err, "drive.permissions.create") if err
        raise Error::Google::Share.new(err) unless err.nil?
      end
    end

    def invite_gdrive_writer(email_address)
      unless ENV['GDRIVE_INVITES_ENABLED'] == 'true'
        raise Error::NotAllowed.new('Google Drive invites are not enabled in this environment')
      end
      permission = Google::Apis::DriveV3::Permission.new(type: :user,
          email_address: email_address,
          role: :writer)
      load_gdrive.create_permission(ENV['GOOGLE_TRANSFER_SHARE'], permission) do |result, err|
        report_google_error(err, "drive.permissions.create_writer") if err
        raise Error::Google::Share.new(err) unless err.nil?
      end
    end

    def self.upload_document(document_name, member, locals, base64_signature, upload_attempt_id: nil)
      sym_name = document_name.to_sym
      raise Error::NotFound.new unless (::Service::GoogleDrive.get_templates().keys.any? { |key| key.to_sym === sym_name })

      merged_locals = (locals || {}).merge({ member: member })

      template_hash = ::Service::GoogleDrive.get_templates()[sym_name]
      pdf_string = ::Service::GoogleDrive.generate_document_string(sym_name, merged_locals, base64_signature)
      pdf_meta = {
        name: ::Service::GoogleDrive.get_document_name(member, sym_name),
        parents: [template_hash[:folder_id]]
      }
      if upload_attempt_id.present?
        pdf_meta[:app_properties] = { DOCUMENT_UPLOAD_ATTEMPT_PROPERTY => upload_attempt_id }
      end
      pdf = Tempfile.new("document", encoding: 'ascii-8bit')
      pdf.write(pdf_string)
      unless Rails.env.test?
        load_gdrive.create_file(pdf_meta,
                    fields: 'id',
                    upload_source: pdf.path,
                    content_type: 'application/pdf'
                    ) do |result, err|
          pdf.close()
          pdf.unlink()
          report_google_error(err, "drive.files.upload_document") if err
          raise Error::Google::Upload.new(err) unless err.nil?
        end
      end
      pdf_string
    end

    def self.get_document_name(member, document_name)
      unique_id = member.kind_of?(Member) ? member.fullname : member.as_json
      "#{unique_id}_#{document_name}_#{Time.now.strftime('%m-%d-%Y')}.pdf"
    end

    def self.generate_document_string(document_name, locals = {}, base64_signature)
      file_name = ::Service::GoogleDrive.get_document_name(locals[:member], document_name)
      template_hash = ::Service::GoogleDrive.get_templates()[document_name]

      full_locals = {}.merge(locals)
      if base64_signature
        safe_signature = ::Service::GoogleDrive.sanitize_base64_signature(base64_signature)
        signature = "<h3>Signature:</h3><img width='100%' src='data:image/png;base64,#{safe_signature}' style='border: 1px solid black' />".html_safe
        full_locals[:signature] = signature
      end

      document = ApplicationController.new.render_to_string(
        "documents/#{document_name.to_s}",
        locals: full_locals,
        layout: false,
        encoding: "UTF-8"
      )

      WickedPdf.new.pdf_from_string(document, page_size: "Letter", dpi: "300")
    end

    def self.sanitize_base64_signature(base64_signature)
      normalized_signature = base64_signature.to_s.delete("\r\n\t ")
      unless normalized_signature.match?(BASE64_SIGNATURE_PATTERN)
        raise Error::UnprocessableEntity.new('Invalid signature')
      end

      Base64.strict_decode64(normalized_signature)
      normalized_signature
    rescue ArgumentError
      raise Error::UnprocessableEntity.new('Invalid signature')
    end

    def upload_document(document_name, member, locals, base64_signature, upload_attempt_id: nil)
      ::Service::GoogleDrive.upload_document(
        document_name,
        member,
        locals,
        base64_signature,
        upload_attempt_id: upload_attempt_id
      )
    end

    def self.upload_backup(file_name)
      backup_meta = {
        name: file_name,
        parents: [ENV['BACKUPS_FOLDER']]
      }
      load_gdrive.create_file(
        backup_meta,
        fields: 'id',
        upload_source: Rails.root.join("dump", file_name).to_s,
      ) do |result, err|
        report_google_error(err, "drive.files.upload_backup") if err
        raise Error::Google::Upload.new(err) unless err.nil?
      end
    end

    def get_document(resource, document_name, upload_attempt_id: nil)
      ::Service::GoogleDrive.get_document(resource, document_name, upload_attempt_id: upload_attempt_id)
    end

    # Filename the archived copy of a signed document is expected to have,
    # derived from the resource's own recorded signed date (not Time.now --
    # that's only used when naming the file at upload time). Shared by
    # get_document and document_uploaded? so both agree on what "the file"
    # means for a given resource.
    def self.expected_document_filename(resource, document_name)
      member_name = resource.kind_of?(Member) ? resource.fullname : resource.member.fullname
      signed_date = resource.kind_of?(Member) ? resource.member_contract_signed_date : resource.contract_signed_date
      return nil if signed_date.nil?

      "#{member_name}_#{document_name}_#{signed_date.strftime('%m-%d-%Y')}.pdf"
    end

    def self.find_document_file(resource, document_name, upload_attempt_id: nil)
      doc_name = expected_document_filename(resource, document_name)
      return nil if doc_name.nil?

      folder_id = get_templates()[document_name.to_sym][:folder_id]

      query = "'#{folder_id}' in parents and name = '#{doc_name}'"
      if upload_attempt_id.present?
        query += " and appProperties has { key='#{DOCUMENT_UPLOAD_ATTEMPT_PROPERTY}' " \
          "and value='#{upload_attempt_id}' }"
      end

      result = report_google_exceptions("drive.files.list") do
        load_gdrive.list_files(
          q: query,
          fields: "files(id, web_content_link)",
        )
      end

      result.files[0]
    end

    # Confirms the archived copy actually exists in Drive -- used right after
    # an upload reports success, since a misconfigured destination folder
    # makes the upload API call succeed without ever raising,
    # even though the file didn't land where get_document will later look.
    def self.document_uploaded?(resource, document_name, upload_attempt_id: nil)
      !find_document_file(resource, document_name, upload_attempt_id: upload_attempt_id).nil?
    end

    def self.get_document(resource, document_name, upload_attempt_id: nil)
      raise ::Error::NotFound.new() if expected_document_filename(resource, document_name).nil?

      first_match = find_document_file(resource, document_name, upload_attempt_id: upload_attempt_id)
      raise ::Error::NotFound.new() if first_match.nil?

      file = Tempfile.new(["#{document_name}_download", ".pdf"], encoding: "ASCII-8BIT")

      report_google_exceptions("drive.files.get") do
        load_gdrive.get_file(first_match.id, download_dest: file)
      end
    end

    def self.report_google_error(error, operation)
      Service::GoogleApiErrorReporter.report_if_permission_denied(
        error,
        operation: operation,
        resource_type: "GoogleDrive"
      )
    end

    def report_google_error(error, operation)
      Service::GoogleDrive.report_google_error(error, operation)
    end

    def self.report_google_exceptions(operation)
      yield
    rescue Google::Apis::Error => error
      report_google_error(error, operation)
      raise
    end
  end
end
