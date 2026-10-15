require "rails_helper"

RSpec.describe ReservationCalendarSyncJob, type: :job do
  let(:reservation) { create(:reservation) }

  it "synchronizes the reservation with the calendar" do
    allow(Service::ReservationCalendar).to receive(:sync!)

    described_class.perform_now(reservation.id.to_s)

    expect(Service::ReservationCalendar).to have_received(:sync!).with(reservation)
  end

  it "no-ops when the reservation no longer exists (Mongoid raise_not_found_error is false)" do
    allow(Service::ReservationCalendar).to receive(:sync!)
    missing_id = reservation.id.to_s
    reservation.destroy

    expect { described_class.perform_now(missing_id) }.not_to raise_error
    expect(Service::ReservationCalendar).not_to have_received(:sync!)
  end

  it "records the sync failure on the reservation and notifies, then reraises for retry" do
    error = StandardError.new("Calendar unavailable")
    allow(Service::ReservationCalendar).to receive(:sync!).and_raise(error)
    allow(Service::GoogleApiErrorReporter).to receive(:report_if_permission_denied)
    allow(Service::GoogleApiErrorReporter).to receive(:full_error_message).and_return("Calendar unavailable")
    allow(Service::ErrorReporter).to receive(:notify)

    expect {
      described_class.new.perform(reservation.id.to_s)
    }.to raise_error(error)

    reservation.reload
    expect(reservation.calendar_sync_status).to eq("failed")
    expect(reservation.calendar_sync_error).to eq("Calendar unavailable")
    expect(Service::ErrorReporter).to have_received(:notify).with(error)
  end
end
