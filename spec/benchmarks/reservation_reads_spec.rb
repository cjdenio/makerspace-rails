require "rails_helper"

# Run explicitly: bundle exec rspec spec/benchmarks/reservation_reads_spec.rb --tag benchmark
# Uses the normal test database safety/cleanup hooks. Slack network calls are mocked.
RSpec.describe "Reservation read benchmark", :benchmark do
  include ReservationReadMeasurement

  [1, 25, 100].each do |count|
    it "measures build, update and portal preview with #{count} tools" do
      ActiveJob::Base.queue_adapter = :test
      member = create(:member, :current)
      shop = create(:shop, reservable: true)
      option = InvoiceOption.create!(name: "Benchmark fee", amount: 10, quantity: 1, resource_class: "fee")
      prerequisite = Tool.new(shop: shop, name: "Prerequisite")
      tools = Array.new(count) do |index|
        Tool.new(shop: shop, name: "Benchmark #{index.to_s.rjust(3, '0')}", reservable: true,
          reservation_prerequisite_tool_ids: [prerequisite.id.to_s],
          duration_fees: [{ "invoice_option_id" => option.id.to_s, "minimum_hours" => 0.5, "maximum_hours" => 1 }])
      end
      Tool.collection.insert_many(([prerequisite] + tools).map(&:attributes))
      ToolCheckout.collection.insert_many(([prerequisite] + tools).map do |tool|
        ToolCheckout.new(member: member, tool: tool, approved_by: member).attributes
      end)
      ids = tools.map { |tool| tool.id.to_s }
      start_at = (Time.current.in_time_zone(ReservationService::ZONE) + 2.days).change(hour: 10, min: 0, sec: 0)
      state = {
        "title" => { "title" => { "value" => "Benchmark" } },
        "scope" => { SlackReservationModal::SCOPE_ACTION_ID => { "selected_option" => { "value" => "tools" } } },
        "tools" => { SlackReservationModal::TOOLS_ACTION_ID => { "selected_options" => ids.map { |id| { "value" => id } } } },
        "date" => { "date" => { "selected_date" => start_at.to_date.iso8601 } },
        "start_time" => { "start_time" => { "selected_time" => "10:00" } },
        "duration" => { "duration" => { "selected_option" => { "value" => "hours:1.0" } } }
      }
      payload = {
        "actions" => [{ "action_id" => SlackReservationModal::TOOLS_ACTION_ID,
          "selected_options" => ids.map { |id| { "value" => id } } }],
        "view" => { "id" => "benchmark", "hash" => "benchmark", "state" => { "values" => state },
          "private_metadata" => { shop_id: shop.id.to_s, member_id: member.id.to_s }.to_json }
      }
      controller = Slack::InteractionsController.new
      allow(controller).to receive(:render)
      allow(Service::SlackConnector).to receive(:update_modal)
      expect(Service::ErrorReporter).not_to receive(:notify)
      operations = {
        build: -> { SlackReservationModal.build(shop, member, reservation_scope: "tools", tool_ids: ids,
          date: start_at.to_date.iso8601, start_time: "10:00", duration: "hours:1.0") },
        update: -> { controller.send(:update_reservation_modal, payload) },
        preview: -> { ReservationService.preview(member: member, attributes: {
          title: "Benchmark", shop_id: shop.id.to_s, reservation_scope: "tools", tool_ids: ids,
          start_at: start_at, end_at: start_at + 1.hour }) }
      }
      operations.each do |operation, run|
        run.call # warm connections and autoloads, not request data
        samples = Array.new(10) { measure_reservation_reads { run.call } }
        times = samples.map { |sample| sample[:elapsed_ms] }.sort
        database = samples.map { |sample| sample[:database_ms] }.sort
        puts "RESERVATION_BENCHMARK #{JSON.generate(operation: operation, resources: count, samples: samples.length,
          reads: samples.map { |sample| sample[:commands].length }.uniq,
          collections: samples.first[:commands].tally.transform_keys { |key| key.join(':') },
          p50_ms: times[4].round(1), p95_ms: times[9].round(1),
          database_p50_ms: database[4].round(1), database_p95_ms: database[9].round(1), slack_network: 'mocked')}"
        expect(samples.last[:result][:eligible]).to eq(true) if operation == :preview
        samples.each do |sample|
          reads = sample[:commands].reject { |command, _| command == "getMore" }.tally
          expect(reads.fetch(["find", "invoice_options"], 0)).to eq(1)
          expect(reads.fetch(["find", "tool_checkouts"], 0)).to eq(1)
          expect(reads.fetch(["find", "tools"], 0)).to eq(operation == :preview ? 1 : 2)
        end
      end
    end
  end
end
