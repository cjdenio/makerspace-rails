require 'rails_helper'

RSpec.describe Service::TurnstileVerifier do
  subject(:verifier) do
    described_class.new(
      token: token,
      remote_ip: remote_ip,
      connection: connection
    )
  end

  let(:token) { 'browser-token' }
  let(:remote_ip) { '203.0.113.42' }
  let(:connection) { instance_double(Faraday::Connection) }
  let(:request) { Struct.new(:headers, :body).new({}, nil) }

  around do |example|
    previous_secret = ENV['TURNSTILE_SECRET']
    ENV['TURNSTILE_SECRET'] = 'test-secret'
    example.run
  ensure
    if previous_secret.nil?
      ENV.delete('TURNSTILE_SECRET')
    else
      ENV['TURNSTILE_SECRET'] = previous_secret
    end
  end

  def stub_response(status:, body:)
    response = instance_double(
      Faraday::Response,
      success?: status.between?(200, 299),
      status: status,
      body: body
    )
    allow(connection).to receive(:post).and_yield(request).and_return(response)
  end

  it 'skips verification when TURNSTILE_SECRET is missing' do
    ENV.delete('TURNSTILE_SECRET')

    expect(connection).not_to receive(:post)
    expect(verifier.valid?).to be(true)
  end

  it 'accepts a successful verification and sends the canonical form body' do
    stub_response(status: 200, body: JSON.generate(success: true))

    expect(verifier.valid?).to be(true)
    expect(request.headers['Content-Type']).to eq('application/x-www-form-urlencoded')
    expect(URI.decode_www_form(request.body).to_h).to eq(
      'secret' => 'test-secret',
      'response' => token,
      'remoteip' => remote_ip
    )
  end

  it 'rejects a missing token without calling siteverify' do
    expect(connection).not_to receive(:post)

    verifier = described_class.new(
      token: '',
      remote_ip: remote_ip,
      connection: connection
    )

    expect(verifier.valid?).to be(false)
  end

  it 'rejects a siteverify response whose success value is not true' do
    stub_response(status: 200, body: JSON.generate(success: false))

    expect(verifier.valid?).to be(false)
  end

  it 'rejects a non-success HTTP response' do
    allow(Rails.logger).to receive(:error)
    stub_response(status: 503, body: 'unavailable')

    expect(verifier.valid?).to be(false)
    expect(Rails.logger).to have_received(:error).with(
      '[Turnstile] siteverify returned HTTP 503'
    )
  end

  it 'rejects malformed JSON' do
    allow(Rails.logger).to receive(:error)
    stub_response(status: 200, body: 'not-json')

    expect(verifier.valid?).to be(false)
    expect(Rails.logger).to have_received(:error).with(
      a_string_including('[Turnstile] siteverify failed: JSON::ParserError')
    )
  end

  it 'rejects connection failures' do
    allow(Rails.logger).to receive(:error)
    allow(connection).to receive(:post).and_raise(
      Faraday::ConnectionFailed.new('connection failed')
    )

    expect(verifier.valid?).to be(false)
    expect(Rails.logger).to have_received(:error).with(
      a_string_including('[Turnstile] siteverify failed: Faraday::ConnectionFailed')
    )
  end

  it 'logs and fails open when siteverify times out' do
    allow(Rails.logger).to receive(:error)
    allow(connection).to receive(:post).and_raise(
      Faraday::TimeoutError.new('request timed out')
    )

    expect(verifier.valid?).to be(true)
    expect(Rails.logger).to have_received(:error).with(
      a_string_including('[Turnstile] siteverify timed out after 20 seconds')
    )
  end
end
