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

  describe ".cached_calendar_color" do
    before { allow(described_class).to receive(:calendar) }

    it "uses the cached palette without ever calling Google" do
      cached = { colors: [{ id: "4", name: "Flamingo", backgroundColor: "#abcdef", foregroundColor: "#000000" }] }
      allow(REDIS).to receive(:get).with(described_class::CALENDAR_COLOR_CACHE_KEY).and_return(JSON.generate(cached))

      expect(described_class.cached_calendar_color("4")).to eq("#abcdef")
      expect(described_class).not_to have_received(:calendar)
    end

    it "falls back to the built-in palette when nothing is cached, and never calls Google" do
      allow(REDIS).to receive(:get).with(described_class::CALENDAR_COLOR_CACHE_KEY).and_return(nil)

      expect(described_class.cached_calendar_color("4")).to eq("#ff887c")
      expect(described_class).not_to have_received(:calendar)
    end

    it "returns nil for a blank or unknown id, and for anything that is not a plain hex color" do
      allow(REDIS).to receive(:get).with(described_class::CALENDAR_COLOR_CACHE_KEY).and_return(nil)
      expect(described_class.cached_calendar_color(nil)).to be_nil
      expect(described_class.cached_calendar_color("")).to be_nil
      expect(described_class.cached_calendar_color("99")).to be_nil

      bad = { colors: [{ id: "4", name: "Odd", backgroundColor: "red;} body{display:none", foregroundColor: "#000000" }] }
      allow(REDIS).to receive(:get).with(described_class::CALENDAR_COLOR_CACHE_KEY).and_return(JSON.generate(bad))
      expect(described_class.cached_calendar_color("4")).to eq("#ff887c")
    end
  end

  describe ".ensure_resource!" do
    let(:directory_service) { double("Google Directory service") }
    let(:calendar_service) do
      double("Google Calendar service", update_acl: nil, insert_acl: nil)
    end

    before do
      allow(described_class).to receive(:directory).and_return(directory_service)
      allow(described_class).to receive(:calendar).and_return(calendar_service)
      allow(directory_service).to receive(:list_calendar_resources).and_return(
        double(items: [], next_page_token: nil)
      )
    end

    it "includes building_id, floor_name, and capacity when creating a Shop's CONFERENCE_ROOM resource" do
      shop = create(:shop, floor_name: "2", capacity: 6)
      created_resource = double(resource_id: "R1", resource_email: "shop@resource.calendar.google.com")

      expect(directory_service).to receive(:calendar_resource) do |_customer_id, resource_object|
        expect(resource_object.resource_category).to eq("CONFERENCE_ROOM")
        expect(resource_object.building_id).to eq("36")
        expect(resource_object.floor_name).to eq("2")
        expect(resource_object.capacity).to eq(6)
        created_resource
      end

      described_class.ensure_resource!(shop, "CONFERENCE_ROOM")

      expect(shop.reload.google_resource_id).to eq("R1")
      expect(calendar_service).to have_received(:update_acl) do |calendar_id, rule_id, rule|
        expect(calendar_id).to eq("shop@resource.calendar.google.com")
        expect(rule_id).to eq("default")
        expect(rule.scope.type).to eq("default")
        expect(rule.role).to eq("freeBusyReader")
      end
    end

    it "does not include location fields for a Tool's OTHER-category resource" do
      tool = create(:tool)
      created_resource = double(resource_id: "R2", resource_email: "tool@resource.calendar.google.com")

      expect(directory_service).to receive(:calendar_resource) do |_customer_id, resource_object|
        expect(resource_object.resource_category).to eq("OTHER")
        expect(resource_object.building_id).to be_nil
        expect(resource_object.floor_name).to be_nil
        expect(resource_object.capacity).to be_nil
        created_resource
      end

      described_class.ensure_resource!(tool, "OTHER")

      expect(tool.reload.google_resource_id).to eq("R2")
    end

    it "logs an ACL Google error and still saves the created resource" do
      shop = create(:shop)
      created_resource = double(
        resource_id: "R3",
        resource_email: "shop-3@resource.calendar.google.com"
      )
      allow(directory_service).to receive(:calendar_resource).and_return(created_resource)
      error = Google::Apis::ServerError.new("ACL unavailable")
      allow(calendar_service).to receive(:update_acl).and_raise(error)
      allow(Rails.logger).to receive(:error)

      expect { described_class.ensure_resource!(shop, "CONFERENCE_ROOM") }.not_to raise_error

      expect(shop.reload.google_resource_id).to eq("R3")
      expect(Rails.logger).to have_received(:error).with(
        include("shop-3@resource.calendar.google.com", "ACL unavailable")
      )
    end

    it "inserts the default ACL when it does not exist yet" do
      tool = create(:tool)
      created_resource = double(
        resource_id: "R5",
        resource_email: "tool-5@resource.calendar.google.com"
      )
      not_found = Google::Apis::ClientError.new("ACL not found")
      allow(not_found).to receive(:status_code).and_return(404)
      allow(directory_service).to receive(:calendar_resource).and_return(created_resource)
      allow(calendar_service).to receive(:update_acl).and_raise(not_found)

      described_class.ensure_resource!(tool, "OTHER")

      expect(calendar_service).to have_received(:insert_acl) do |calendar_id, rule|
        expect(calendar_id).to eq("tool-5@resource.calendar.google.com")
        expect(rule.scope.type).to eq("default")
        expect(rule.role).to eq("freeBusyReader")
      end
    end

    it "reapplies the ACL when an existing resource is unchanged" do
      shop = create(
        :shop,
        google_resource_id: "R4",
        resource_email: "old-address@resource.calendar.google.com"
      )
      resource = double(
        resource_id: "R4",
        resource_name: shop.name,
        resource_email: "shop-4@resource.calendar.google.com"
      )
      allow(directory_service).to receive(:get_calendar_resource).and_return(resource)

      described_class.ensure_resource!(shop, "CONFERENCE_ROOM")

      expect(directory_service).not_to have_received(:list_calendar_resources)
      expect(calendar_service).to have_received(:update_acl).with(
        "shop-4@resource.calendar.google.com",
        "default",
        an_instance_of(Google::Apis::CalendarV3::AclRule)
      )
    end
  end
end
