require "rails_helper"

RSpec.describe ReservationSlackCanvasSyncJob do
  let(:shop) { create(:shop, slack_channel: "woodshop") }

  it "logs the configured Slack channel when canvas synchronization fails" do
    error = Slack::Web::Api::Errors::CanvasEditingFailed.new(
      "canvas_editing_failed"
    )
    allow(Service::ReservationSlackCanvas).to receive(:sync!).and_raise(error)
    allow(Honeybadger).to receive(:notify) if defined?(Honeybadger)
    expect(Rails.logger).to receive(:error).with(
      a_string_including(
        "[ReservationSlackCanvasError]",
        "shop_id=#{shop.id}",
        'slack_channel="woodshop"',
        "dates=2026-07-24",
        "CanvasEditingFailed: canvas_editing_failed"
      )
    )

    expect {
      described_class.new.perform(shop.id.to_s, ["2026-07-24"])
    }.to raise_error(Slack::Web::Api::Errors::CanvasEditingFailed)
  end
end
