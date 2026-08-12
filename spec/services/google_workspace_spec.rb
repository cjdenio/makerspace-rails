require "rails_helper"

RSpec.describe Service::GoogleWorkspace do
  describe ".calendar_colors" do
    let(:calendar_service) { double("Google Calendar service") }

    before do
      allow(described_class).to receive(:calendar).and_return(calendar_service)
      allow(calendar_service).to receive(:respond_to?).with(:get_colors).and_return(false)
      allow(calendar_service).to receive(:get_color)
      allow(REDIS).to receive(:get).with(described_class::CALENDAR_COLOR_CACHE_KEY).and_return(nil)
      allow(REDIS).to receive(:set).and_return(true)
    end

    it "uses Google's event palette and excludes calendar-only color IDs" do
      event_definitions = {
        "1" => double(background: "#a4bdfc", foreground: "#1d1d1d"),
        "11" => double(background: "#dc2127", foreground: "#1d1d1d")
      }
      calendar_definitions = {
        "24" => double(background: "#a47ae2", foreground: "#1d1d1d")
      }
      allow(calendar_service).to receive(:get_color).and_return(
        double(calendar: calendar_definitions, event: event_definitions)
      )

      colors = described_class.calendar_colors

      expect(colors).to eq(
        [
          {
            id: "1", name: "Lavender",
            backgroundColor: "#a4bdfc", foregroundColor: "#1d1d1d"
          },
          {
            id: "11", name: "Tomato",
            backgroundColor: "#dc2127", foregroundColor: "#1d1d1d"
          }
        ]
      )
      expect(colors.map { |color| color[:id] }).not_to include("24")
      expect(calendar_service).to have_received(:get_color).once
    end

    it "returns the Google event palette represented by color IDs 1 through 11 when colors are unavailable" do
      allow(calendar_service).to receive(:get_color).and_raise(
        StandardError, "colors endpoint unavailable"
      )

      colors = described_class.calendar_colors

      expect(colors.map { |color| color[:name] }).to eq(
        %w[Lavender Sage Grape Flamingo Banana Tangerine Peacock Graphite Blueberry Basil Tomato]
      )
      expect(colors.map { |color| [color[:id], color[:backgroundColor]] }).to eq(
        [
          ["1", "#a4bdfc"], ["2", "#7ae7bf"], ["3", "#dbadff"],
          ["4", "#ff887c"], ["5", "#fbd75b"], ["6", "#ffb878"],
          ["7", "#46d6db"], ["8", "#e1e1e1"], ["9", "#5484ed"],
          ["10", "#51b749"], ["11", "#dc2127"]
        ]
      )
      expect(colors.map { |color| color[:foregroundColor] }.uniq).to eq(["#1d1d1d"])
    end

    it "uses Redis and appends a valid existing event color missing from the selected list" do
      cached = {
        colors: [
          {
            id: "1", name: "Lavender",
            backgroundColor: "#a4bdfc", foregroundColor: "#1d1d1d"
          }
        ],
        allColors: [
          {
            id: "1", name: "Lavender",
            backgroundColor: "#a4bdfc", foregroundColor: "#1d1d1d"
          },
          {
            id: "9", name: "Blueberry",
            backgroundColor: "#5484ed", foregroundColor: "#1d1d1d"
          }
        ]
      }
      allow(REDIS).to receive(:get).and_return(JSON.generate(cached))

      colors = described_class.calendar_colors(include_color_id: "9")

      expect(colors.last).to include(
        id: "9",
        name: "Blueberry",
        backgroundColor: "#5484ed"
      )
      expect(calendar_service).not_to have_received(:get_color)
      expect(REDIS).to have_received(:set).with(
        described_class::CALENDAR_COLOR_CACHE_KEY,
        include('"id":"9"')
      )
    end

    it "does not expose an existing calendar-only color ID" do
      cached = {
        colors: described_class::FALLBACK_CALENDAR_COLORS,
        allColors: described_class::FALLBACK_CALENDAR_COLORS
      }
      allow(REDIS).to receive(:get).and_return(JSON.generate(cached))

      colors = described_class.calendar_colors(include_color_id: "24")

      expect(colors.map { |color| color[:id] }).not_to include("24")
      expect(REDIS).not_to have_received(:set)
    end
  end
end
