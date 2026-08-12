require "rails_helper"

RSpec.describe ReservationSlackReminderSyncJob, type: :job do
  let(:reservation) { create(:reservation) }

  it "synchronizes the reservation reminder" do
    allow(Service::ReservationSlackReminder).to receive(:sync!)

    described_class.perform_now(reservation.id.to_s)

    expect(Service::ReservationSlackReminder).to have_received(:sync!)
      .with(reservation)
  end

  it "logs and reraises Slack failures for Active Job retries" do
    error = StandardError.new("Slack unavailable")
    allow(Service::ReservationSlackReminder).to receive(:sync!).and_raise(error)
    allow(Rails.logger).to receive(:error)
    allow(Honeybadger).to receive(:notify)

    expect {
      expect {
        described_class.new.perform(reservation.id.to_s)
      }.to raise_error(error)
    }.to output(
      a_string_including(
        "[ReservationSlackReminderError]",
        "reservation_id=#{reservation.id}",
        "Slack unavailable"
      )
    ).to_stderr

    expect(Honeybadger).to have_received(:notify).with(error)
  end
end
