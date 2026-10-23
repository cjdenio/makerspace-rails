require "rails_helper"

RSpec.describe SlackChannelCacheRefreshJob, type: :job do
  before do
    allow(Service::SlackChannelCache).to receive(:rebuild!).and_return(42)
    allow(SystemConfig).to receive(:record_run)
  end

  it "clears and rebuilds the cache and records success" do
    expect(described_class.perform_now).to eq(42)

    expect(Service::SlackChannelCache).to have_received(:rebuild!)
    expect(SystemConfig).to have_received(:record_run)
      .with("slack_channel_cache", success: true)
  end

  it "records and reports a failed rebuild" do
    error = StandardError.new("Slack unavailable")
    allow(Service::SlackChannelCache).to receive(:rebuild!).and_raise(error)
    allow(Honeybadger).to receive(:notify)

    expect { described_class.perform_now }.to raise_error(error)

    expect(SystemConfig).to have_received(:record_run)
      .with("slack_channel_cache", success: false)
    expect(Honeybadger).to have_received(:notify).with(
      "SlackChannelCacheRefreshJob failed",
      context: { error: "Slack unavailable" }
    )
  end
end
