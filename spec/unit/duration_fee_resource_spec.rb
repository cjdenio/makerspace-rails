require "mongoid"
require_relative "../../app/models/concerns/duration_fee_resource"

RSpec.describe DurationFeeResource do
  before do
    stub_const("DurationFeeTestResource", Class.new)
    DurationFeeTestResource.class_eval do
      include Mongoid::Document
      include DurationFeeResource
      field :max_reservation_duration_hours, type: Float, default: 8
    end
  end

  it "loads the shared Mongoid fields with backwards-compatible defaults" do
    resource = DurationFeeTestResource.new
    expect(resource.reservation_full_day).to eq(false)
    expect(resource.duration_fees).to eq([])
    expect(resource.minimum_advance_notice_hours).to eq(2)
    expect(resource.prohibit_same_day_reservations).to eq(false)
  end

  it "accepts zero notice and rejects negative or missing notice" do
    resource = DurationFeeTestResource.new(minimum_advance_notice_hours: 0)
    expect(resource).to be_valid
    resource.minimum_advance_notice_hours = -1
    expect(resource).not_to be_valid
    resource.minimum_advance_notice_hours = nil
    expect(resource).not_to be_valid
  end

  it "requires whole-day maximums only when full-day reservations are required" do
    resource = DurationFeeTestResource.new(reservation_full_day: true)
    expect(resource).not_to be_valid
    resource.max_reservation_duration_hours = 24
    expect(resource).to be_valid
    resource.max_reservation_duration_hours = 25
    expect(resource).not_to be_valid
    resource.reservation_full_day = false
    expect(resource).to be_valid
  end
end
