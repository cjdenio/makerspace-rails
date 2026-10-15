require 'rails_helper'

RSpec.describe MembershipExpirationNoticeJob, type: :job do
  before do
    allow(Service::MembershipExpirationNotice).to receive(:run!)
    allow(SystemConfig).to receive(:record_run)
  end

  it 'runs the service and records success' do
    described_class.perform_now
    expect(Service::MembershipExpirationNotice).to have_received(:run!)
    expect(SystemConfig).to have_received(:record_run).with('membership_expiration_notice', success: true)
  end

  it 'records and reports failure' do
    error = StandardError.new('Mongo unavailable')
    allow(Service::MembershipExpirationNotice).to receive(:run!).and_raise(error)
    allow(Honeybadger).to receive(:notify)

    expect { described_class.perform_now }.to raise_error(error)

    expect(SystemConfig).to have_received(:record_run).with('membership_expiration_notice', success: false)
    expect(Honeybadger).to have_received(:notify).with('MembershipExpirationNoticeJob failed', context: { error: 'Mongo unavailable' })
  end
end
