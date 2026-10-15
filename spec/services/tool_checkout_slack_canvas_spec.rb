require "rails_helper"

RSpec.describe Service::ToolCheckoutSlackCanvas do
  let(:shop) { create(:shop, name: "Wood Shop", slack_channel: "woodshop") }

  it 'refreshes availability warnings independently of Hidden' do
    shop.set(checkout_canvas_id: 'FCHECKOUTS')
    tool = create(:tool, shop: shop)
    expect { tool.update!(out_of_service: true) }.to have_enqueued_job(ToolCheckoutSlackCanvasSyncJob).with(shop.id.to_s)
    expect(described_class.canvas_markdown(shop)).to include('Out of service - do not use.')
    tool.update!(disabled: true)
    expect(described_class.canvas_markdown(shop)).not_to include('Out of service - do not use.')
    tool.update!(out_of_service: false)
    expect(tool.reload.disabled).to be(true)
  end

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(Service::SlackChannelCache).to receive(:lookup)
      .with("#woodshop").and_return({ id: "C123ABC456" })
    allow(Service::SlackConnector).to receive(:find_channel_id)
    allow(Service::SlackConnector).to receive(:create_canvas)
      .and_return("FCHECKOUTS")
    allow(Service::SlackConnector).to receive(:set_canvas_user_access)
    allow(Service::SlackConnector).to receive(:set_canvas_channel_access)
    allow(Service::SlackConnector).to receive(:replace_canvas)
    allow(Service::SlackConnector).to receive(:lookup_canvas_sections)
    allow(Service::SlackConnector).to receive(:edit_canvas)
  end


  it "inserts one new checkout at the start of its tool section and refreshes the timestamp" do
    shop.update!(checkout_canvas_id: "FCHECKOUTS")
    tool = create(:tool, shop: shop, name: "Table Saw")
    member = create(:member, :current, firstname: "Amy", lastname: "Zimmer")
    checkout = ToolCheckout.create!(member: member, tool: tool)
    allow(Service::SlackConnector).to receive(:lookup_canvas_sections) do |_canvas_id, contains_text:, **|
      [double(id: contains_text == "Last updated" ? "STIMESTAMP" : "STOOL")]
    end

    travel_to Time.zone.parse("2026-09-16 20:15:00 UTC") do
      described_class.sync_checkout!(checkout, action: "add")
    end

    expect(Service::SlackConnector).to have_received(:lookup_canvas_sections)
      .with("FCHECKOUTS", contains_text: "Current checkouts for Table Saw:", section_types: nil)
    expect(Service::SlackConnector).to have_received(:edit_canvas) do |canvas_id, changes|
      expect(canvas_id).to eq("FCHECKOUTS")
      expect(changes.first).to eq(
        operation: "insert_after",
        section_id: "STOOL",
        document_content: { type: "markdown", markdown: "- :white_check_mark: Amy Zimmer" }
      )
      expect(changes.last).to include(operation: "replace", section_id: "STIMESTAMP")
      expect(changes.last.dig(:document_content, :markdown)).to include("September 16, 2026 at 16:15 EDT")
    end
  end

  it "deletes one revoked checkout section and refreshes the timestamp" do
    shop.update!(checkout_canvas_id: "FCHECKOUTS")
    tool = create(:tool, shop: shop, name: "Table Saw")
    checkout = ToolCheckout.create!(
      member: create(:member, :current, firstname: "Amy", lastname: "Zimmer"),
      tool: tool,
      revoked_at: Time.current
    )
    allow(Service::SlackConnector).to receive(:lookup_canvas_sections) do |_canvas_id, contains_text:, **|
      [double(id: contains_text == "Last updated" ? "STIMESTAMP" : "SCHECKOUT")]
    end

    described_class.sync_checkout!(checkout, action: "remove")

    expect(Service::SlackConnector).to have_received(:lookup_canvas_sections).with(
      "FCHECKOUTS",
      contains_text: "- :white_check_mark: Amy Zimmer",
      section_types: nil
    )
    expect(Service::SlackConnector).to have_received(:edit_canvas) do |_canvas_id, changes|
      expect(changes.first).to eq(operation: "delete", section_id: "SCHECKOUT")
      expect(changes.last).to include(operation: "replace", section_id: "STIMESTAMP")
    end
  end

  it "rebuilds instead of deleting when the member line occurs in multiple tool sections" do
    shop.update!(checkout_canvas_id: "FCHECKOUTS")
    checkout = ToolCheckout.create!(
      member: create(:member, :current, firstname: "Amy", lastname: "Zimmer"),
      tool: create(:tool, shop: shop),
      revoked_at: Time.current
    )
    allow(Service::SlackConnector).to receive(:lookup_canvas_sections)
      .and_return([double(id: "SONE"), double(id: "STWO")])
    allow(described_class).to receive(:sync!)

    described_class.sync_checkout!(checkout, action: "remove")

    expect(Service::SlackConnector).not_to have_received(:edit_canvas)
    expect(described_class).to have_received(:sync!).with(shop)
  end

  it "does not incrementally add an inactive member" do
    shop.update!(checkout_canvas_id: "FCHECKOUTS")
    checkout = ToolCheckout.create!(
      member: create(:member, :expired),
      tool: create(:tool, shop: shop)
    )
    allow(Service::SlackConnector).to receive(:lookup_canvas_sections)
      .and_return([double(id: "STIMESTAMP")])

    described_class.sync_checkout!(checkout, action: "add")

    expect(Service::SlackConnector).to have_received(:lookup_canvas_sections).once.with(
      "FCHECKOUTS", contains_text: "Last updated", section_types: nil
    )
    expect(Service::SlackConnector).to have_received(:edit_canvas) do |_canvas_id, changes|
      expect(changes.map { |change| change[:operation] }).to eq(["replace"])
    end
  end

  it "falls back to a complete rebuild when an incremental lookup fails" do
    shop.update!(checkout_canvas_id: "FCHECKOUTS")
    checkout = ToolCheckout.create!(
      member: create(:member, :current),
      tool: create(:tool, shop: shop)
    )
    allow(Service::SlackConnector).to receive(:lookup_canvas_sections).and_return([])
    allow(described_class).to receive(:sync!)

    described_class.sync_checkout!(checkout, action: "add")

    expect(described_class).to have_received(:sync!).with(shop)
    expect(Service::SlackConnector).not_to have_received(:edit_canvas)
  end

  it "creates, caches, shares, and populates a read-only shop checkout canvas" do
    admin = create(:member, :admin)
    rm = create(
      :member,
      :resource_manager,
      firstname: "Zoe",
      lastname: "Anderson",
      resource_manager_shop_ids: [shop.id.to_s]
    )
    member = create(:member, :current, firstname: "Amy", lastname: "Zimmer")
    expired = create(:member, :expired)
    SlackUser.create!(
      member: rm,
      slack_id: "URM123456",
      name: "zoë\\`*_{}[]()#+-.!|>@anderson"
    )
    SlackUser.create!(member: admin, slack_id: "UADMIN123")
    prerequisite = create(:tool, shop: shop, name: "Orientation")
    tool = create(
      :tool,
      shop: shop,
      name: "Table Saw",
      description: "Cuts lumber",
      wiki_url: "https://example.test/table-saw",
      prerequisite_ids: [prerequisite.id.to_s]
    )
    hidden = create(:tool, shop: shop, name: "Hidden Tool", disabled: true)
    ToolCheckout.create!(member: rm, tool: tool, approved_by: admin)
    ToolCheckout.create!(member: member, tool: tool, approved_by: admin)
    ToolCheckout.create!(member: expired, tool: tool, approved_by: admin)
    ToolCheckout.create!(member: member, tool: hidden, approved_by: admin)

    described_class.sync!(shop)

    expect(shop.reload.checkout_canvas_id).to eq("FCHECKOUTS")
    expect(Service::SlackConnector).to have_received(:create_canvas)
      .with("Wood Shop Checkouts", channel_id: "C123ABC456")
    expect(Service::SlackConnector).to have_received(:set_canvas_channel_access)
      .with("FCHECKOUTS", "C123ABC456")
    expect(Service::SlackConnector).to have_received(:replace_canvas) do |_id, markdown|
      expect(markdown).to include("# Wood Shop Checkouts")
      expect(markdown).to include("Current tool checkouts in ![](#C123ABC456)")
      expect(markdown).to include("- Table Saw")
      expect(markdown).not_to include("[Table Saw](#table-saw)")
      expect(markdown).to include("### Table Saw", "Cuts lumber ([Table Saw Wiki](https://example.test/table-saw))")
      expect(markdown).to include("Pre-requisites: Orientation")
      expect(markdown).to include("**Current checkouts for Table Saw:**")
      expect(markdown).to include("- :ballot_box_with_check: zoanderson")
      expect(markdown).to include("- :white_check_mark: Amy Zimmer")
      expect(markdown).to match(
        /\*\*Current checkouts for Table Saw:\*\*\n- :ballot_box_with_check: zoanderson\n- :white_check_mark: Amy Zimmer/
      )
      expect(markdown).not_to include("![](@URM123456)", "zoë")
      expect(markdown).not_to include("Hidden Tool", expired.fullname)
      expect(markdown.index("Zoe Anderson")).to be_nil
      expect(markdown).to match(/_Last updated .+\._/)
    end
  end

  it "does not create an unshared canvas when the channel cannot be resolved" do
    allow(Service::SlackChannelCache).to receive(:lookup).and_return(nil)
    allow(Service::SlackConnector).to receive(:find_channel_id).and_return(nil)

    described_class.sync!(shop)

    expect(Service::SlackConnector).not_to have_received(:create_canvas)
  end

  it "resolves private channels through Slack when they are absent from the public cache" do
    allow(Service::SlackChannelCache).to receive(:lookup).and_return(nil)
    expect(Service::SlackConnector).to receive(:find_channel_id)
      .with("#woodshop").and_return("GPRIVATE01")

    described_class.sync!(shop)

    expect(Service::SlackConnector).to have_received(:create_canvas)
      .with("Wood Shop Checkouts", channel_id: "GPRIVATE01")
  end

  it "reports a rebuild failure and continues to the next recorded canvas" do
    failed_shop = create(:shop, checkout_canvas_id: "FFAIL")
    successful_shop = create(:shop, checkout_canvas_id: "FSUCCESS")
    allow(described_class).to receive(:sync!).with(failed_shop)
      .and_raise(StandardError, "not found")
    allow(described_class).to receive(:sync!).with(successful_shop)
    allow(described_class).to receive(:report_failure)

    described_class.rebuild_all!

    expect(described_class).to have_received(:report_failure)
      .with(failed_shop, an_instance_of(StandardError))
    expect(described_class).to have_received(:sync!).with(successful_shop)
  end

  it "sends failures to the interface log channel and records an audit entry" do
    error = StandardError.new("canvas not found")
    allow(Service::AuditLogger).to receive(:log)

    described_class.report_failure(shop, error)

    expect(Service::AuditLogger).to have_received(:log).with(
      hash_including(
        event_type: "checkout_canvas_sync_failed",
        resource_id: shop.id,
        message_details: a_string_including(":warning:", "canvas not found"),
        slack_channel: Service::SlackConnector.logs_channel
      )
    )
  end
end
