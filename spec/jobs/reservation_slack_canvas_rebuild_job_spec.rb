require "rails_helper"
require "rake"

RSpec.describe ReservationSlackCanvasRebuildJob, type: :job do
  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("reservations:rebuild_slack_canvases")
    Rake::Task["reservations:rebuild_slack_canvases"].reenable
    allow(Service::ReservationSlackCanvas).to receive(:rebuild_all!)
    allow(SystemConfig).to receive(:record_run)
  end

  it "runs the rake task and records a successful automated-job run" do
    described_class.perform_now

    expect(Service::ReservationSlackCanvas).to have_received(:rebuild_all!)
    expect(SystemConfig).to have_received(:record_run)
      .with("reservation_canvas_rebuild", success: true)
  end

  it "records and reports a failed automated-job run" do
    error = StandardError.new("Slack unavailable")
    allow(Service::ReservationSlackCanvas).to receive(:rebuild_all!)
      .and_raise(error)
    allow(Honeybadger).to receive(:notify)

    expect { described_class.perform_now }.to raise_error(error)

    expect(SystemConfig).to have_received(:record_run)
      .with("reservation_canvas_rebuild", success: false)
    expect(Honeybadger).to have_received(:notify).with(
      "ReservationSlackCanvasRebuildJob failed",
      context: { error: "Slack unavailable" }
    )
  end
end
