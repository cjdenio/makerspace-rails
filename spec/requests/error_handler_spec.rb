require 'rails_helper'

RSpec.describe 'Error handling', type: :request do
  describe 'ActionController::ParameterMissing' do
    before do
      allow(Service::SlackConnector).to receive(:enque_message)
      allow(SlackMessagesJob).to receive(:perform_later)
    end

    it 'does not enqueue a Slack alert in production' do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))

      post '/api/client_error_handler', params: {}

      expect(response).to have_http_status(:unprocessable_content)
      expect(Service::SlackConnector).not_to have_received(:enque_message)
      expect(SlackMessagesJob).not_to have_received(:perform_later)
    end

    it 'retains Slack alerts outside production' do
      post '/api/client_error_handler', params: {}

      expect(response).to have_http_status(:unprocessable_content)
      expect(Service::SlackConnector).to have_received(:enque_message).with(
        a_string_matching(/param is missing.*message/),
        Service::SlackConnector.logs_channel,
        anything
      )
      expect(SlackMessagesJob).to have_received(:perform_later)
    end
  end
end
