require 'rails_helper'

RSpec.describe ApplicationController, type: :controller do
  describe '#log_not_found_file_lookup_context' do
    it 'logs only the requested path and translated file lookup locations' do
      request_double = instance_double(
        ActionDispatch::Request,
        path: '/missing/file.png'
      )
      allow(controller).to receive(:request).and_return(request_double)
      allow(Rails.logger).to receive(:info)

      controller.send(:log_not_found_file_lookup_context)

      expect(Rails.logger).to have_received(:info) do |message|
        expect(message).to include('[404 file lookup]')
        expect(message).to include('requested_path=/missing/file.png')
        expect(message).to include(Rails.root.join('public', 'missing/file.png').to_s)
        expect(message).not_to include('cache=false')
      end
    end

    it 'does not log raw query string secrets' do
      request_double = instance_double(
        ActionDispatch::Request,
        original_fullpath: '/api/members/change_password.xml?password=secret',
        path: '/api/members/change_password.xml'
      )
      allow(controller).to receive(:request).and_return(request_double)
      allow(Rails.logger).to receive(:info)

      controller.send(:log_not_found_file_lookup_context)

      expect(Rails.logger).to have_received(:info) do |message|
        expect(message).to include('requested_path=/api/members/change_password.xml')
        expect(message).not_to include('password=secret')
      end
    end
  end

  describe '#translated_file_lookup_locations' do
    it 'normalizes traversal paths before translating them to local locations' do
      request_double = instance_double(
        ActionDispatch::Request,
        path: '/../secret.txt'
      )
      allow(controller).to receive(:request).and_return(request_double)

      expect(controller.send(:translated_file_lookup_locations)).to include(Rails.root.join('public').to_s)
      expect(controller.send(:translated_file_lookup_locations)).not_to include(a_string_matching('secret.txt'))
    end
  end
end
