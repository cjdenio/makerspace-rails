require "rails_helper"

RSpec.describe ReservationTiming do
  it "reports only safe metrics and returns the original result" do
    messages = []
    allow(Rails.logger).to receive(:info) { |message| messages << JSON.parse(message) }
    result = described_class.measure("reservation_preview") do |metrics|
      metrics[:resource_count] = 3
      metrics[:outcome] = "rejected"
      { title: "private reservation title", eligible: false }
    end
    expect(result[:eligible]).to eq(false)
    expect(messages.last.keys).to match_array(%w[event operation resource_count outcome elapsed_ms])
    expect(messages.last).to include("resource_count" => 3, "outcome" => "rejected")
    expect(messages.last["elapsed_ms"]).to be >= 0
    expect(messages.last.to_json).not_to include("private reservation title")
  end

  it "records errors without swallowing them or logging their message" do
    expect(Rails.logger).to receive(:info) do |message|
      expect(JSON.parse(message)["outcome"]).to eq("error")
      expect(message).not_to include("private token")
    end
    expect { described_class.measure("slack_views_update") { raise "private token" } }
      .to raise_error(RuntimeError, "private token")
  end
end
