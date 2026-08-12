require "rails_helper"

RSpec.describe GoogleResourceDeleteJob, type: :job do
  before do
    allow(Service::GoogleApiErrorReporter)
      .to receive(:report_if_permission_denied)
    allow(Honeybadger).to receive(:notify)
  end

  it "attempts label deletion and raises when resource deletion fails" do
    error = StandardError.new("transient directory failure")
    allow(Service::GoogleWorkspace).to receive(:delete_resource!)
      .and_raise(error)
    allow(Service::GoogleWorkspace).to receive(:delete_label!)

    expect {
      described_class.new.perform("calendar-resource", "label-source")
    }.to raise_error(error)

    expect(Service::GoogleWorkspace).to have_received(:delete_label!)
      .with("label-source")
  end

  it "raises when label deletion fails after resource deletion succeeds" do
    error = StandardError.new("transient calendar failure")
    allow(Service::GoogleWorkspace).to receive(:delete_resource!)
    allow(Service::GoogleWorkspace).to receive(:delete_label!)
      .and_raise(error)

    expect {
      described_class.new.perform("calendar-resource", "label-source")
    }.to raise_error(error)

    expect(Service::GoogleWorkspace).to have_received(:delete_resource!)
      .with("calendar-resource", audit_resource_id: "label-source")
  end
end
