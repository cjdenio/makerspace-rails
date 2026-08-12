require "rails_helper"

RSpec.describe ReservationBlackout do
  let(:zone) { ReservationService::ZONE }
  let(:blackout) do
    create(
      :reservation_blackout,
      recurrence: "weekly",
      weekday: 1,
      start_time: "20:00",
      end_time: "02:00",
      start_date: Date.new(2026, 7, 20),
      end_date: Date.new(2026, 7, 27)
    )
  end

  it "generates bounded overnight weekly occurrences" do
    occurrence = blackout.occurrence_on(Date.new(2026, 7, 27))

    expect(occurrence[:start_at]).to eq(zone.local(2026, 7, 27, 20, 0).utc)
    expect(occurrence[:end_at]).to eq(zone.local(2026, 7, 28, 2, 0).utc)
    expect(blackout.occurrence_on(Date.new(2026, 8, 3))).to be_nil
  end

  it "treats equal times as a 24-hour occurrence" do
    blackout.update!(recurrence: "daily", weekday: nil, start_time: "09:00", end_time: "09:00")
    occurrence = blackout.occurrence_on(Date.new(2026, 7, 27))

    expect(occurrence[:end_at].in_time_zone(zone))
      .to eq(zone.local(2026, 7, 28, 9, 0))
  end

  it "does not turn DST-normalized equality into an overnight occurrence" do
    blackout.update!(
      recurrence: "daily",
      weekday: nil,
      start_time: "02:30",
      end_time: "03:30",
      start_date: Date.new(2026, 3, 8),
      end_date: Date.new(2026, 3, 8)
    )

    expect(blackout.occurrence_on(Date.new(2026, 3, 8))).to be_nil
    expect(
      blackout.occurrences_overlapping(
        zone.local(2026, 3, 8, 0, 0),
        zone.local(2026, 3, 9, 0, 0)
      )
    ).to be_empty
  end

  it "requires half-hour boundaries and ordered date bounds" do
    record = build(
      :reservation_blackout,
      start_time: "17:15",
      start_date: Date.new(2026, 7, 28),
      end_date: Date.new(2026, 7, 27)
    )

    expect(record).not_to be_valid
    expect(record.errors[:start_time]).to be_present
    expect(record.errors[:end_date]).to be_present
  end

  it "finds an overnight occurrence from the prior local date" do
    range_start = zone.local(2026, 7, 28, 1, 0)
    range_end = zone.local(2026, 7, 28, 3, 0)

    expect(blackout.occurrences_overlapping(range_start, range_end).length).to eq(1)
  end
end
