require 'rails_helper'

RSpec.describe CardExpirationCheckJob, type: :job do
  before do
    allow(Service::CardExpirationCheck).to receive(:run!)
    allow(SystemConfig).to receive(:record_run)
  end

  it 'runs the service without requiring Rake and records success' do
    hide_const('Rake') if Object.const_defined?(:Rake)

    described_class.perform_now

    expect(Service::CardExpirationCheck).to have_received(:run!)
    expect(SystemConfig).to have_received(:record_run)
      .with('card_expiration_check', success: true)
  end

  it 'records and reports failure' do
    error = StandardError.new('Braintree unavailable')
    allow(Service::CardExpirationCheck).to receive(:run!).and_raise(error)
    allow(Honeybadger).to receive(:notify)

    expect { described_class.perform_now }.to raise_error(error)
    expect(SystemConfig).to have_received(:record_run)
      .with('card_expiration_check', success: false)
    expect(Honeybadger).to have_received(:notify).with(
      'CardExpirationCheckJob failed',
      context: { error: 'Braintree unavailable' }
    )
  end
end
