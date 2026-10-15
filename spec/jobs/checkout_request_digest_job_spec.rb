require "rails_helper"

RSpec.describe CheckoutRequestDigestJob, type: :job do
  before { allow(SystemConfig).to receive(:record_run) }

  it "delivers the digests and records success" do
    allow(CheckoutRequestDigest).to receive(:deliver_all!)

    described_class.perform_now

    expect(CheckoutRequestDigest).to have_received(:deliver_all!)
    expect(SystemConfig).to have_received(:record_run).with("checkout_request_digest", success: true)
  end

  it "records and reports a failure of the run itself" do
    error = StandardError.new("Mongo unavailable")
    allow(CheckoutRequestDigest).to receive(:deliver_all!).and_raise(error)
    allow(Service::ErrorReporter).to receive(:notify)

    expect { described_class.perform_now }.to raise_error(error)

    expect(SystemConfig).to have_received(:record_run).with("checkout_request_digest", success: false)
    expect(Service::ErrorReporter).to have_received(:notify).with(error)
  end
end
