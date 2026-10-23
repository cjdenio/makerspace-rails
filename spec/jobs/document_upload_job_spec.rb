require 'rails_helper'

RSpec.describe DocumentUploadJob, type: :job do
  before do
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::AuditLogger).to receive(:log)
    allow(MemberMailer).to receive(:send_document).and_return(double(deliver_later: true))
  end

  describe '#perform' do
    it 'suppresses automatic argument logging so the encoded signature is not exposed' do
      expect(described_class.log_arguments).to be false
    end

    it 'sends the document mailer when the upload is verified in Drive' do
      member = create(:member)
      allow(Service::GoogleDrive).to receive(:upload_document).and_return('pdf-bytes')
      allow(Service::GoogleDrive).to receive(:document_uploaded?).and_return(true)
      allow(Rails.logger).to receive(:info)

      described_class.new.perform('signature-data', 'member_contract', member.id.as_json)

      expect(Rails.logger).to have_received(:info).with(
        a_string_including(
          "resource=Member(#{member.id})",
          "member=#{member.fullname.inspect}",
          'document_type="member_contract"'
        )
      )
      expect(Rails.logger).not_to have_received(:info).with(a_string_including('signature-data'))
      expect(MemberMailer).to have_received(:send_document).with('member_contract', member.id.as_json, 'pdf-bytes')
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end

    it 'does not upload a duplicate when the expected document already exists' do
      member = create(:member, member_contract_signed_date: Date.new(2026, 9, 13))
      job = described_class.new
      job.executions = 2
      downloaded = Tempfile.new('existing-doc')
      downloaded.binmode
      downloaded.write('existing-pdf-bytes')
      downloaded.rewind
      allow(Service::GoogleDrive).to receive(:document_uploaded?).and_return(true)
      allow(Service::GoogleDrive).to receive(:upload_document)
      allow(Service::GoogleDrive).to receive(:generate_document_string)
      allow(Service::GoogleDrive).to receive(:get_document).and_return(downloaded)
      allow(Rails.logger).to receive(:info)

      job.perform('signature-data', 'member_contract', member.id.as_json)

      expect(Service::GoogleDrive).to have_received(:document_uploaded?).with(
        member,
        'member_contract',
        upload_attempt_id: job.job_id
      ).twice
      expect(Service::GoogleDrive).not_to have_received(:upload_document)
      # Reads back the file already confirmed present instead of
      # re-rendering, so the email attaches exactly what's archived --
      # scoped to this attempt's own tag, same as the precheck above, so an
      # earlier same-day signing's file (same filename) can't be fetched by
      # mistake.
      expect(Service::GoogleDrive).to have_received(:get_document).with(
        member,
        'member_contract',
        upload_attempt_id: job.job_id
      )
      expect(Service::GoogleDrive).not_to have_received(:generate_document_string)
      expect(Rails.logger).to have_received(:info).with(a_string_including('skipping duplicate Drive upload'))
      expect(MemberMailer).to have_received(:send_document).with(
        'member_contract',
        member.id.as_json,
        'existing-pdf-bytes'
      )
    ensure
      downloaded.close!
    end

    it 'uploads on retry when only an earlier signing attempt has the same filename' do
      member = create(:member, member_contract_signed_date: Date.new(2026, 9, 13))
      job = described_class.new
      job.executions = 2
      allow(Service::GoogleDrive).to receive(:document_uploaded?).and_return(false, true)
      allow(Service::GoogleDrive).to receive(:upload_document).and_return('new-pdf-bytes')

      job.perform('new-signature-data', 'member_contract', member.id.as_json)

      expect(Service::GoogleDrive).to have_received(:upload_document).with(
        'member_contract',
        member,
        {},
        'new-signature-data',
        upload_attempt_id: job.job_id
      )
      expect(MemberMailer).to have_received(:send_document).with(
        'member_contract',
        member.id.as_json,
        'new-pdf-bytes'
      )
    end

    it 'raises when the upload reports success but the file cannot be found afterward' do
      member = create(:member, member_contract_signed_date: Date.new(2026, 9, 13))
      allow(Service::GoogleDrive).to receive(:upload_document).and_return('pdf-bytes')
      allow(Service::GoogleDrive).to receive(:document_uploaded?).and_return(false)
      allow(Service::GoogleDrive).to receive(:get_templates).and_return(
        member_contract: { folder_id: 'member-contract-folder-id' }
      )
      expected_filename = "#{member.fullname}_member_contract_09-13-2026.pdf"

      expect {
        described_class.new.perform('signature-data', 'member_contract', member.id.as_json)
      }.to raise_error(
        Error::Google::Upload,
        a_string_including(
          "member=#{member.fullname.inspect}",
          "resource=Member(#{member.id})",
          'document_type="member_contract"',
          "expected_filename=#{expected_filename.inspect}",
          'folder_id="member-contract-folder-id"',
          'upload_attempt_id="'
        )
      )

      expect(MemberMailer).not_to have_received(:send_document)
    end

    it 'lets a genuine upload error from Drive propagate the same way' do
      member = create(:member)
      allow(Service::GoogleDrive).to receive(:document_uploaded?).and_return(false)
      allow(Service::GoogleDrive).to receive(:upload_document).and_raise(Error::Google::Upload.new)

      expect {
        described_class.new.perform('signature-data', 'member_contract', member.id.as_json)
      }.to raise_error(Error::Google::Upload)
    end
  end

  describe '#report_upload_failure (final-failure alerting, invoked once retries are exhausted)' do
    it 'alerts Slack, writes an audit log entry, and rolls back the signed date for a member contract' do
      member = create(:member, member_contract_signed_date: Date.today)
      error = Error::Google::Upload.new('boom')

      described_class.new.send(:report_upload_failure, 'member_contract', member.id.as_json, error)

      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        a_string_matching(/#{Regexp.escape(member.fullname)}.*member_contract.*boom/)
      )
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(
          event_type: 'document_upload_failed',
          resource_type: 'Member',
          resource_id: member.id.as_json,
          subject: member
        )
      )
      expect(member.reload.member_contract_signed_date).to be_nil
    end

    it 'alerts Slack, writes an audit log entry, and rolls back contract_on_file for a rental agreement' do
      rental = create(:rental, contract_signed_date: Date.today)
      error = Error::Google::Upload.new('boom')

      described_class.new.send(:report_upload_failure, 'rental_agreement', rental.id.as_json, error)

      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(
          event_type: 'document_upload_failed',
          resource_type: 'Rental',
          resource_id: rental.id.as_json,
          subject: rental.member
        )
      )
      expect(rental.reload.contract_signed_date).to be_nil
    end

    it 'does not raise if reporting itself fails, so the original failure is never masked' do
      member = create(:member)
      allow(Service::SlackConnector).to receive(:send_slack_message).and_raise('slack is down')

      expect {
        described_class.new.send(:report_upload_failure, 'member_contract', member.id.as_json, Error::Google::Upload.new)
      }.not_to raise_error
    end
  end
end
