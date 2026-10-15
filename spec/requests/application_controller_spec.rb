require 'rails_helper'

RSpec.describe 'ApplicationController#application', type: :request do
  describe 'GET /' do
    it 'renders the layout for a normal HTML request' do
      get '/'

      expect(response).to have_http_status(200)
    end

    it 'returns 404 for an explicit non-html format param, without reaching the html-only layout' do
      get '/', params: { format: :json }

      expect(response).to have_http_status(404)
      expect(response.body).to eq('Not Found')
    end

    it 'returns 404 for a bare path negotiated to JSON via the Accept header (e.g. a bot/scanner probe)' do
      get '/', as: :json

      expect(response).to have_http_status(404)
      expect(response.body).to eq('Not Found')
    end
  end
end
