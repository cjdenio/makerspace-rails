require 'rails_helper'

RSpec.describe Service::GoogleDrive do
  describe '.upload_document' do
    it 'tags the Drive file with the upload attempt ID used for retry deduplication' do
      member = create(:member)
      drive = double
      allow(described_class).to receive(:get_templates).and_return(
        member_contract: { folder_id: 'folder-1' }
      )
      allow(described_class).to receive(:generate_document_string).and_return('pdf-bytes')
      allow(described_class).to receive(:load_gdrive).and_return(drive)
      allow(Rails.env).to receive(:test?).and_return(false)

      expect(drive).to receive(:create_file).with(
        hash_including(
          parents: ['folder-1'],
          app_properties: { 'document_upload_job_id' => 'current-job-id' }
        ),
        fields: 'id',
        upload_source: kind_of(String),
        content_type: 'application/pdf'
      ).and_yield(double(id: 'drive-file-id'), nil)

      expect(described_class.upload_document(
        'member_contract',
        member,
        {},
        'signature-data',
        upload_attempt_id: 'current-job-id'
      )).to eq('pdf-bytes')
    end
  end

  describe '.sanitize_base64_signature' do
    it 'normalizes valid base64 signature data' do
      signature = Base64.encode64('signature-bytes')

      expect(described_class.sanitize_base64_signature(signature)).to eq(Base64.strict_encode64('signature-bytes'))
    end

    it 'rejects signature data that could inject HTML into the PDF template' do
      injected_signature = "' /><iframe src='http://169.254.169.254/latest/meta-data/'></iframe>"

      expect { described_class.sanitize_base64_signature(injected_signature) }
        .to raise_error(Error::UnprocessableEntity, 'Invalid signature')
    end
  end

  describe '.generate_document_string' do
    it 'resolves the documents/member_contract template instead of raising MissingTemplate' do
      member = create(:member)
      allow(described_class).to receive(:get_templates).and_return({ member_contract: {} })
      allow(WickedPdf).to receive(:new).and_return(double(pdf_from_string: 'pdf-bytes'))

      signature = Base64.strict_encode64('signature-bytes')
      result = described_class.generate_document_string(:member_contract, { member: member }, signature)

      expect(result).to eq('pdf-bytes')
    end
  end

  describe '.expected_document_filename' do
    it "builds the filename from the resource's recorded signed date, not Time.now" do
      member = create(:member, member_contract_signed_date: Date.new(2020, 7, 18))

      expect(described_class.expected_document_filename(member, 'member_contract'))
        .to eq("#{member.fullname}_member_contract_07-18-2020.pdf")
    end

    it 'returns nil when the resource has no signed date yet' do
      member = create(:member, member_contract_signed_date: nil)

      expect(described_class.expected_document_filename(member, 'member_contract')).to be_nil
    end
  end

  describe '.document_uploaded?' do
    before do
      allow(described_class).to receive(:get_templates).and_return(member_contract: { folder_id: 'folder-1' })
    end

    it 'is true when a matching file exists in the configured folder' do
      member = create(:member, member_contract_signed_date: Date.new(2020, 7, 18))
      allow(described_class).to receive(:load_gdrive).and_return(double(list_files: double(files: [double(id: '1')])))

      expect(described_class.document_uploaded?(member, 'member_contract')).to be true
    end

    it 'is false when no matching file exists (e.g. the upload landed in the wrong folder)' do
      member = create(:member, member_contract_signed_date: Date.new(2020, 7, 18))
      allow(described_class).to receive(:load_gdrive).and_return(double(list_files: double(files: [])))

      expect(described_class.document_uploaded?(member, 'member_contract')).to be false
    end

    it 'is false when the resource has no signed date yet, without calling Drive at all' do
      member = create(:member, member_contract_signed_date: nil)
      allow(described_class).to receive(:load_gdrive)

      expect(described_class.document_uploaded?(member, 'member_contract')).to be false
      expect(described_class).not_to have_received(:load_gdrive)
    end

    it 'restricts an attempt-specific lookup to the file tagged by that upload job' do
      member = create(:member, member_contract_signed_date: Date.new(2020, 7, 18))
      drive = double(list_files: double(files: [double(id: '1')]))
      allow(described_class).to receive(:load_gdrive).and_return(drive)

      expect(described_class.document_uploaded?(
        member,
        'member_contract',
        upload_attempt_id: 'current-job-id'
      )).to be true
      expect(drive).to have_received(:list_files).with(
        q: a_string_including(
          "appProperties has { key='document_upload_job_id' and value='current-job-id' }"
        ),
        fields: 'files(id, web_content_link)'
      )
    end
  end

  describe '.get_document' do
    before do
      allow(described_class).to receive(:get_templates).and_return(member_contract: { folder_id: 'folder-1' })
    end

    it 'raises NotFound when no file matches' do
      member = create(:member, member_contract_signed_date: Date.new(2020, 7, 18))
      allow(described_class).to receive(:load_gdrive).and_return(double(list_files: double(files: [])))

      expect { described_class.get_document(member, 'member_contract') }.to raise_error(Error::NotFound)
    end

    it 'downloads the matched file' do
      member = create(:member, member_contract_signed_date: Date.new(2020, 7, 18))
      matched_file = double(id: 'file-1', web_content_link: 'link')
      drive = double(list_files: double(files: [matched_file]))
      allow(drive).to receive(:get_file) { |_id, download_dest:| download_dest.write('pdf-bytes'); download_dest.flush; download_dest }
      allow(described_class).to receive(:load_gdrive).and_return(drive)

      result = described_class.get_document(member, 'member_contract')

      expect(File.read(result.path)).to eq('pdf-bytes')
    end

    # Without this, a retry's email could attach an EARLIER same-day
    # signing's file instead of the one just verified for this attempt --
    # the download must be scoped the same way the precheck already is.
    it 'restricts the download to the file tagged by the given upload attempt' do
      member = create(:member, member_contract_signed_date: Date.new(2020, 7, 18))
      matched_file = double(id: 'file-1', web_content_link: 'link')
      drive = double(list_files: double(files: [matched_file]))
      allow(drive).to receive(:get_file) { |_id, download_dest:| download_dest.write('pdf-bytes'); download_dest.flush; download_dest }
      allow(described_class).to receive(:load_gdrive).and_return(drive)

      described_class.get_document(member, 'member_contract', upload_attempt_id: 'current-job-id')

      expect(drive).to have_received(:list_files).with(
        q: a_string_including(
          "appProperties has { key='document_upload_job_id' and value='current-job-id' }"
        ),
        fields: 'files(id, web_content_link)'
      )
    end
  end
end
