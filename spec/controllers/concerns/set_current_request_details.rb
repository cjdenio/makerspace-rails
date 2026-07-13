require 'rails_helper'

RSpec.describe SetCurrentRequestDetails, type: :controller do
  controller(ActionController::Base) do
    include SetCurrentRequestDetails

    def index
      render plain: Current.ip_address
    end
  end

  before do
    routes.draw { get 'index' => 'anonymous#index' }
    allow(controller.request).to receive(:cloudflare?).and_return(false)
  end

  after do
    Rails.application.reload_routes!
  end

  it 'uses the Cloudflare connecting IP header when present on a Cloudflare request' do
    allow(controller.request).to receive(:cloudflare?).and_return(true)
    request.headers['CF-Connecting-IP'] = '203.0.113.42'

    get :index

    expect(response.body).to eq('203.0.113.42')
  end

  it 'supports IPv6 addresses from the Cloudflare connecting IP header' do
    allow(controller.request).to receive(:cloudflare?).and_return(true)
    request.headers['CF-Connecting-IP'] = '2001:db8::1'

    get :index

    expect(response.body).to eq('2001:db8::1')
  end

  it 'falls back to request.ip when no Cloudflare IP header is present' do
    allow(controller.request).to receive(:cloudflare?).and_return(true)
    request.remote_addr = '198.51.100.10'

    get :index

    expect(response.body).to eq('198.51.100.10')
  end

  it 'ignores Cloudflare client IP headers when the request did not arrive through Cloudflare' do
    request.remote_addr = '198.51.100.10'
    request.headers['CF-Connecting-IP'] = '203.0.113.42'

    get :index

    expect(response.body).to eq('198.51.100.10')
  end

  it 'uses the Cloudflare true client IP header when present on a Cloudflare request' do
    allow(controller.request).to receive(:cloudflare?).and_return(true)
    request.headers['True-Client-IP'] = '198.51.100.44'

    get :index

    expect(response.body).to eq('198.51.100.44')
  end
end
