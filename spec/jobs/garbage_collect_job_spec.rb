require 'rails_helper'

RSpec.describe GarbageCollectJob do
  before do
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::SlackConnector).to receive(:logs_channel).and_return('logs')
  end

  it 'cleans the invoice cache and records a successful run' do
    allow(InvoiceHelper).to receive(:clean_cache)

    described_class.perform_now

    expect(InvoiceHelper).to have_received(:clean_cache)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      a_string_including('Pruned Redis invoicing cache'), 'logs'
    )
    expect(SystemConfig.job_status('garbage_collect')[:last_run_status]).to eq('success')
  end

  it 'records a failed run, notifies, and re-raises on error' do
    allow(InvoiceHelper).to receive(:clean_cache).and_raise(StandardError, 'redis unavailable')
    allow(Service::ErrorReporter).to receive(:notify)

    expect { described_class.perform_now }.to raise_error(StandardError, 'redis unavailable')

    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      a_string_including('Error cleaning Redis'), 'logs'
    )
    expect(SystemConfig.job_status('garbage_collect')[:last_run_status]).to eq('failure')
    expect(Service::ErrorReporter).to have_received(:notify).with(
      'GarbageCollectJob failed', context: { error: 'redis unavailable' }
    )
  end
end
