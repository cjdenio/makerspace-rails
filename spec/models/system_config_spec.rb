require 'rails_helper'

RSpec.describe SystemConfig do
  describe '.scheduled_day_matches?' do
    it 'defaults to day 1 when unset' do
      travel_to(Time.zone.local(2026, 9, 1)) do
        expect(described_class.scheduled_day_matches?('some_job_day')).to be(true)
      end
      travel_to(Time.zone.local(2026, 9, 2)) do
        expect(described_class.scheduled_day_matches?('some_job_day')).to be(false)
      end
    end

    it 'uses the configured day when set' do
      described_class.set('some_job_day', '15')

      travel_to(Time.zone.local(2026, 9, 15)) do
        expect(described_class.scheduled_day_matches?('some_job_day')).to be(true)
      end
      travel_to(Time.zone.local(2026, 9, 1)) do
        expect(described_class.scheduled_day_matches?('some_job_day')).to be(false)
      end
    end

    it 'accepts a different default' do
      travel_to(Time.zone.local(2026, 9, 20)) do
        expect(described_class.scheduled_day_matches?('another_job_day', default: 20)).to be(true)
      end
    end
  end
end
