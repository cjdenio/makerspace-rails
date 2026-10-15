require "rails_helper"

RSpec.describe GoogleResourceSyncJob, type: :job do
  let(:shop) { create(:shop) }

  before do
    allow(Service::GoogleApiErrorReporter)
      .to receive(:report_if_permission_denied)
    allow(Honeybadger).to receive(:notify)
    allow(Rails.logger).to receive(:warn)
  end

  it "does nothing when the source record was deleted before a retry" do
    missing_id = BSON::ObjectId.new.to_s
    allow(Service::GoogleWorkspace).to receive(:ensure_resource!)
    allow(Service::GoogleWorkspace).to receive(:ensure_label!)

    expect {
      described_class.new.perform("Shop", missing_id)
    }.not_to raise_error

    expect(Service::GoogleWorkspace).not_to have_received(:ensure_resource!)
    expect(Service::GoogleWorkspace).not_to have_received(:ensure_label!)
    expect(Service::GoogleApiErrorReporter)
      .not_to have_received(:report_if_permission_denied)
    expect(Honeybadger).not_to have_received(:notify)
    expect(Rails.logger).not_to have_received(:warn)
  end

  it "propagates synchronization errors for Active Job retry handling" do
    error = StandardError.new("transient directory failure")
    allow(Service::GoogleWorkspace).to receive(:ensure_resource!)
      .and_raise(error)

    expect {
      described_class.new.perform("Shop", shop.id.to_s)
    }.to raise_error(error)
  end

  it "redacts authorization headers before logging and retry propagation" do
    error = StandardError.new(
      '#<Faraday::Response request_headers={' \
      '"Authorization"=>"Bearer super-secret-token"}>'
    )
    allow(Service::GoogleWorkspace).to receive(:ensure_resource!)
      .and_raise(error)

    expect {
      described_class.new.perform("Shop", shop.id.to_s)
    }.to raise_error(error)

    expect(error.message).to include('"Authorization"=>"[FILTERED]"')
    expect(error.message).not_to include("super-secret-token")
    expect(Rails.logger).to have_received(:warn).with(
      include('"Authorization"=>"[FILTERED]"')
    )
    expect(Rails.logger).not_to have_received(:warn).with(
      include("super-secret-token")
    )
  end

  it "reports permission errors before propagating them" do
    error = StandardError.new("PERMISSION_DENIED: owner access required")
    allow(Service::GoogleWorkspace).to receive(:ensure_resource!)
      .and_raise(error)

    expect {
      described_class.new.perform("Shop", shop.id.to_s)
    }.to raise_error(error)

    expect(Service::GoogleApiErrorReporter)
      .to have_received(:report_if_permission_denied).with(
        error,
        operation: "google_resource_sync_job",
        resource_type: "Shop",
        resource_id: shop.id.to_s
      )
  end

  it "propagates a label failure after ensuring the resource" do
    error = StandardError.new("transient calendar failure")
    allow(Service::GoogleWorkspace).to receive(:ensure_resource!)
    allow(Service::GoogleWorkspace).to receive(:ensure_label!)
      .and_raise(error)

    expect {
      described_class.new.perform("Shop", shop.id.to_s)
    }.to raise_error(error)

    expect(Service::GoogleWorkspace).to have_received(:ensure_resource!)
      .with(shop, "CONFERENCE_ROOM")
    expect(Service::GoogleWorkspace).to have_received(:ensure_label!)
      .with(shop)
  end
end
