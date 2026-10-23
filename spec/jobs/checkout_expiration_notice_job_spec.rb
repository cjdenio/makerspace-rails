require "rails_helper"

RSpec.describe CheckoutExpirationNoticeJob, type: :job do
  before { allow(SystemConfig).to receive(:record_run) }

  it "delivers expiration notices and records success" do
    allow(CheckoutExpirationNotice).to receive(:run!)

    described_class.perform_now

    expect(CheckoutExpirationNotice).to have_received(:run!)
    expect(SystemConfig).to have_received(:record_run).with("checkout_expiration_notice", success: true)
  end

  it "records and reports a failure of the run itself" do
    error = StandardError.new("Mongo unavailable")
    allow(CheckoutExpirationNotice).to receive(:run!).and_raise(error)
    allow(Service::ErrorReporter).to receive(:notify)

    expect { described_class.perform_now }.to raise_error(error)

    expect(SystemConfig).to have_received(:record_run).with("checkout_expiration_notice", success: false)
    expect(Service::ErrorReporter).to have_received(:notify).with(error)
  end
end
