require "rails_helper"

RSpec.describe SlackReservationModal do
  let(:member) do
    instance_double(
      Member,
      id: BSON::ObjectId.new,
      status: "activeMember",
      role: "member",
      active_unexpired?: true
    )
  end
  let(:tools) { [] }
  let(:prerequisite_tools) { [] }
  let(:relation) { double("reservable tool relation") }
  let(:prerequisite_relation) { double("prerequisite relation", to_a: prerequisite_tools) }
  let(:checkout_relation) { double("checkout relation", pluck: checked_out_tool_ids) }
  let(:checked_out_tool_ids) { [] }
  let(:shop) { resource_double(Shop, name: "Woodshop", reservable: true) }

  before do
    allow(Tool).to receive(:where) do |criteria|
      criteria.key?(:reservable) ? relation : prerequisite_relation
    end
    allow(relation).to receive(:order_by).with(name: :asc).and_return(relation)
    allow(relation).to receive(:to_a).and_return(tools)
    allow(prerequisite_relation).to receive(:only).with(:name).and_return(prerequisite_relation)
    allow(ToolCheckout).to receive(:where).and_return(checkout_relation)
  end

  def resource_double(klass, overrides = {})
    defaults = {
      id: BSON::ObjectId.new,
      name: klass == Shop ? "Woodshop" : "Tool",
      reservable: true,
      reservation_horizon_days: 7,
      minimum_advance_notice_hours: 2,
      prohibit_same_day_reservations: false,
      max_reservation_duration_hours: 8.0,
      reservation_full_day: false,
      reservation_requires_approval: false,
      reservation_prerequisite_tool_ids: [],
      duration_fees: []
    }
    defaults.merge!(disabled?: false, out_of_service?: false) if klass == Shop
    defaults.merge!(effective_reservation_prerequisite_ids: [], allow_pending: false) if klass == Tool
    defaults.merge!(shop_id: shop.id, disabled?: false) if klass == Tool
    instance_double(klass, **defaults.merge(overrides))
  end

  context 'when the entire shop is out of service' do
    it 'rejects the modal before querying reservation options' do
      allow(shop).to receive(:out_of_service?).and_return(true)
      expect(Tool).not_to receive(:where)
      expect { described_class.build(shop, member) }.to raise_error(Error::UnprocessableEntity, /out of service/)
    end
  end

  def block(view, block_id)
    view[:blocks].find { |candidate| candidate[:block_id] == block_id }
  end

  def policy_text(view)
    block(view, "reservation_policy_details").dig(:text, :text)
  end

  def duration_values(view)
    block(view, "duration").dig(:element, :options).pluck(:value)
  end

  it "builds a shop-only view with Duration and an informational policy alert" do
    view = described_class.build(shop, member)

    expect(block(view, "scope")[:element][:options]).to contain_exactly(hash_including(value: "shop"))
    expect(block(view, "tools")).to be_nil
    expect(block(view, "end_time")).to be_nil
    expect(block(view, "duration")).to be_present
    expect(block(view, "reservation_policy")).to include(type: "alert", level: "info")
    expect(block(view, "reservation_policy").dig(:text, :text).length).to be <= 200
    expect(block(view, "reservation_policy_details").dig(:text, :type)).to eq("mrkdwn")
    expect(block(view, "start_time").dig(:element, :timezone)).to eq("America/New_York")
    expect(block(view, "reservation_calculated_end").dig(:text, :text))
      .to include("Calculated end", "America/New_York")
    expect(block(view, "scope")).to include(dispatch_action: true)
    expect(block(view, "scope").dig(:element, :action_id)).to eq("reservation_scope_changed")
  end

  it "keeps the default date synchronized when the next half hour is tomorrow" do
    travel_to ReservationService::ZONE.local(2026, 9, 17, 23, 45) do
      view = described_class.build(shop, member)

      expect(block(view, "date").dig(:element, :initial_date)).to eq("2026-09-18")
      expect(block(view, "start_time").dig(:element, :initial_time)).to eq("00:00")
    end
  end

  it "previews positive fees and directs the member to the portal" do
    allow(ReservationFeeService).to receive(:quote).and_return([
      { resourceName: "Woodshop", name: "Hourly reservation", units: 2, amount: 12.5 }
    ])
    allow(ReservationFeeService).to receive(:total).and_return(12.5)

    view = described_class.build(shop, member)

    expect(block(view, "reservation_policy")).to include(level: "error")
    expect(block(view, "reservation_policy").dig(:text, :text)).to include("$12.50", "Member Portal")
    expect(block(view, "reservation_fee_preview").dig(:text, :text)).to include("Woodshop", "$12.50")
    expect(view.dig(:submit, :text)).to eq("Use Member Portal")
  end

  it "builds a tool-only view and selects its first tool" do
    allow(shop).to receive(:reservable).and_return(false)
    tools << resource_double(Tool, name: "Bandsaw")

    view = described_class.build(shop, member)

    expect(block(view, "scope")[:element][:options]).to contain_exactly(hash_including(value: "tools"))
    expect(block(view, "tools")[:element][:initial_options]).to contain_exactly(hash_including(value: tools.first.id.to_s))
    expect(policy_text(view)).to include("Bandsaw")
  end

  it "hides tools whose effective checkout requirements are not met" do
    restricted = resource_double(Tool, name: "Restricted")
    allow(restricted).to receive(:effective_reservation_prerequisite_ids)
      .and_return([restricted.id.to_s])
    tools << restricted

    view = described_class.build(shop, member)

    expect(block(view, "tools")).to be_nil
    expect(block(view, "scope")[:element][:options].pluck(:value)).to eq(["shop"])
  end

  it "exposes a restricted tool after the member has its required checkout" do
    restricted = resource_double(Tool, name: "Restricted")
    allow(restricted).to receive(:effective_reservation_prerequisite_ids)
      .and_return([restricted.id.to_s])
    tools << restricted
    checked_out_tool_ids << restricted.id

    view = described_class.build(shop, member)

    expect(block(view, "tools")[:element][:options]).to contain_exactly(
      hash_including(value: restricted.id.to_s)
    )
  end

  it "hides tools with unmet explicit reservation prerequisites" do
    prerequisite_id = BSON::ObjectId.new
    tools << resource_double(
      Tool,
      name: "Advanced Tool",
      effective_reservation_prerequisite_ids: [prerequisite_id.to_s],
      reservation_prerequisite_tool_ids: [prerequisite_id.to_s]
    )

    expect(block(described_class.build(shop, member), "tools")).to be_nil
  end

  it "allows board members to see enabled reservable tools without checkouts" do
    board_member = instance_double(
      Member,
      id: BSON::ObjectId.new,
      status: "activeMember",
      role: "board_member",
      active_unexpired?: true
    )
    restricted = resource_double(Tool, effective_reservation_prerequisite_ids: [BSON::ObjectId.new.to_s])
    tools << restricted

    expect(block(described_class.build(shop, board_member), "tools")[:element][:options])
      .to contain_exactly(hash_including(value: restricted.id.to_s))
  end

  it "supports mixed scope and applies selected-tool policies" do
    tools << resource_double(Tool, name: "Lathe", reservation_horizon_days: 3)

    shop_view = described_class.build(shop, member)
    tool_view = described_class.build(shop, member, reservation_scope: "tools", tool_ids: [tools.first.id])

    expect(block(shop_view, "scope")[:element][:options].pluck(:value)).to eq(%w[shop tools])
    expect(policy_text(shop_view)).to include("Woodshop")
    expect(policy_text(tool_view)).to include("Lathe", "3 days")
  end

  it "preserves entered state when rebuilding a view" do
    tools << resource_double(Tool, name: "Lathe")

    view = described_class.update(
      shop: shop, member: member, response_url: "https://example.test/response",
      slack_user_id: "U123", reservation_scope: "tools", tool_ids: [tools.first.id],
      title: "Careful setup", date: "2026-10-02", start_time: "14:30", duration: "hours:2.5"
    )

    expect(block(view, "title").dig(:element, :initial_value)).to eq("Careful setup")
    expect(block(view, "date").dig(:element, :initial_date)).to eq("2026-10-02")
    expect(block(view, "start_time").dig(:element, :initial_time)).to eq("14:30")
    expect(block(view, "duration").dig(:element, :initial_option, :value)).to eq("hours:2.5")
    expect(block(view, "tools")).to include(dispatch_action: true)
    expect(block(view, "tools").dig(:element, :action_id)).to eq("reservation_tools_changed")
  end

  it "clamps a preserved duration to the greatest newly valid choice" do
    allow(shop).to receive(:max_reservation_duration_hours).and_return(4.0)

    view = described_class.build(shop, member, duration: "hours:8")

    expect(block(view, "duration").dig(:element, :initial_option, :value)).to eq("hours:4.0")
  end

  it "keeps a review submit action for incompatible multi-tool notice and horizon policies" do
    tools.concat([
      resource_double(Tool, name: "Immediate Window", reservation_horizon_days: 0),
      resource_double(Tool, name: "No Same Day", prohibit_same_day_reservations: true)
    ])

    view = described_class.build(
      shop, member, reservation_scope: "tools", tool_ids: tools.map(&:id)
    )

    expect(view.dig(:submit, :text)).to eq("Review selection")
    expect(block(view, "duration")).to be_nil
    expect(policy_text(view)).to include(
      "Unavailable combination", "Immediate Window", "No Same Day", "cannot be reserved together"
    )
  end

  it "explains when full-day and maximum-duration rules leave no valid duration" do
    tools.concat([
      resource_double(Tool, name: "Kiln", reservation_full_day: true,
        max_reservation_duration_hours: 24),
      resource_double(Tool, name: "Short Session", max_reservation_duration_hours: 8)
    ])

    view = described_class.build(
      shop, member, reservation_scope: "tools", tool_ids: tools.map(&:id)
    )

    expect(view.dig(:submit, :text)).to eq("Review selection")
    expect(policy_text(view)).to include("No duration is valid", "Kiln", "Short Session")
  end

  it "offers half-hour choices through five hours and whole-hour choices beyond" do
    allow(shop).to receive(:max_reservation_duration_hours).and_return(8.0)

    expect(duration_values(described_class.build(shop, member))).to eq(
      %w[hours:0.5 hours:1.0 hours:1.5 hours:2.0 hours:2.5 hours:3.0 hours:3.5 hours:4.0 hours:4.5 hours:5.0 hours:6 hours:7 hours:8]
    )
  end

  it "uses coarser long-duration steps and never exceeds Slack's 100-option limit" do
    allow(shop).to receive(:max_reservation_duration_hours).and_return(1_000.0)

    values = duration_values(described_class.build(shop, member))

    expect(values.length).to eq(100)
    expect(values).to include("hours:24", "hours:26", "hours:48", "hours:52")
    expect(values).not_to include("hours:25", "hours:50", "hours:53")
  end

  it "treats full-day reservations as starting no earlier than tomorrow" do
    allow(shop).to receive_messages(
      reservation_full_day: true,
      max_reservation_duration_hours: 24.0,
      reservation_horizon_days: 0,
      minimum_advance_notice_hours: 0
    )

    travel_to ReservationService::ZONE.local(2026, 9, 17, 9, 0) do
      view = described_class.build(shop, member)

      expect(view.dig(:submit, :text)).to eq("Review selection")
      expect(policy_text(view)).to include("Unavailable combination", "earliest start of September 18")
    end
  end

  it "caps full-day duration choices at Slack's 100-option limit" do
    allow(shop).to receive_messages(
      reservation_full_day: true,
      max_reservation_duration_hours: 24.0 * 150
    )

    expect(duration_values(described_class.build(shop, member)).length).to eq(100)
  end

  it "offers whole-day choices and removes the start-time input for full-day resources" do
    allow(shop).to receive_messages(reservation_full_day: true, max_reservation_duration_hours: 72.0)

    view = described_class.build(shop, member)

    expect(duration_values(view)).to eq(%w[days:1 days:2 days:3])
    expect(block(view, "start_time")).to be_nil
    expect(policy_text(view)).to include("whole days", "3 days")
  end

  it "summarizes approval, notice, horizon, same-day, and prerequisite rules" do
    prerequisite = resource_double(Tool, name: "Safety Orientation")
    prerequisite_tools << prerequisite
    allow(shop).to receive_messages(
      reservation_requires_approval: true,
      minimum_advance_notice_hours: 6.0,
      reservation_horizon_days: 2,
      prohibit_same_day_reservations: true,
      reservation_prerequisite_tool_ids: [prerequisite.id.to_s]
    )

    text = policy_text(described_class.build(shop, member))

    expect(text).to include("Manager approval", "6 hours", "2 days", "Same-day", "Safety Orientation")
  end

  it "uses strictest selected rules and names resources when their rules differ" do
    tools.concat([
      resource_double(Tool, name: "Lathe", reservation_horizon_days: 10,
        minimum_advance_notice_hours: 2, max_reservation_duration_hours: 8),
      resource_double(Tool, name: "Mill", reservation_horizon_days: 3,
        minimum_advance_notice_hours: 6, max_reservation_duration_hours: 4)
    ])

    view = described_class.build(
      shop, member, reservation_scope: "tools", tool_ids: tools.map(&:id)
    )
    text = policy_text(view)

    expect(duration_values(view).last).to eq("hours:4.0")
    expect(text).to include("3 days", "6 hours", "Maximum duration: 4 hours", "Lathe", "Mill", "Rules differ")
  end

  it "rejects more than 100 reservable tools" do
    tools.concat(101.times.map { |index| resource_double(Tool, name: "Tool #{index}") })

    expect { described_class.build(shop, member) }
        .to raise_error(Error::UnprocessableEntity, "This shop has more than 100 reservable resources; use the portal")
  end
end

RSpec.describe 'Slack reservation picker availability' do
  it 'excludes hidden and unavailable tools, including when all tools are unavailable' do
    shop = create(:shop, reservable: false)
    member = build(:member, :current)
    # open: true -- otherwise Tool#effective_reservation_prerequisite_ids
    # makes every tool its own prerequisite (the "must already have a
    # supervised checkout on this tool" training gate), which an unsaved
    # member with no checkout history can never satisfy. That gate is
    # unrelated to what this test verifies (out_of_service/disabled
    # exclusion), so it's turned off here.
    available = create(:tool, shop: shop, reservable: true, open: true)
    legacy = create(:tool, shop: shop, reservable: true, open: true)
    legacy.unset(:out_of_service)
    create(:tool, shop: shop, reservable: true, open: true, disabled: true)
    create(:tool, shop: shop, reservable: true, open: true, out_of_service: true)
    view = SlackReservationModal.build(shop, member)
    options = view[:blocks].find { |b| b[:block_id] == 'tools' }[:element][:options]
    expect(options.pluck(:value)).to contain_exactly(available.id.to_s, legacy.id.to_s)
    [available, legacy].each { |tool| tool.set(out_of_service: true) }
    expect { SlackReservationModal.build(shop, member) }.to raise_error(Error::UnprocessableEntity, /no reservable resources/)
    shop.set(reservable: true)
    expect(SlackReservationModal.build(shop, member)[:blocks].pluck(:block_id)).not_to include('tools')
  end
end

RSpec.describe 'Slack group reservation prerequisites' do
  it 'warns about group requirements without reserving them or applying their duration limits' do
    shop = create(:shop, reservable: true)
    member = create(:member, :current)
    included = create(:tool, shop: shop, reservable: true, open: true, max_reservation_duration_hours: 4)
    prerequisite = create(:tool, shop: shop, name: 'Group orientation', max_reservation_duration_hours: 0.5)
    group = ToolGroup.create!(shop: shop, name: 'Starter kit', reservable: true,
      included_tool_ids: [included.id.to_s], prerequisite_ids: [prerequisite.id.to_s])
    build = -> { SlackReservationModal.build(shop, member, reservation_scope: 'tools', tool_ids: ["group:#{group.id}"]) }
    view = build.call
    expect(view[:blocks].find { |block| block[:block_id] == 'reservation_policy' }[:text][:text]).to include('Missing required checkout(s): Group orientation')
    expect(view[:blocks].find { |block| block[:block_id] == 'reservation_policy_details' }[:text][:text]).to include('Required active checkout(s): Group orientation')
    expect(view[:submit][:text]).to eq('Review selection')
    duration = view[:blocks].find { |block| block[:block_id] == 'duration' }
    expect(duration[:element][:options].last[:value]).to eq('hours:4.0')

    ToolCheckout.create!(member: member, tool: prerequisite, defer_users_channel_invitation: true)
    expect(build.call[:submit][:text]).to eq('Reserve')
    # Switching to the whole shop discards the previous group selection's rules.
    ToolCheckout.where(member_id: member.id).delete_all
    expect(SlackReservationModal.build(shop, member, reservation_scope: 'shop', tool_ids: ["group:#{group.id}"])[:submit][:text]).to eq('Reserve')
  end
end
