require "rails_helper"

RSpec.describe ToolAvailabilityService do
  let(:zone) { ReservationService::ZONE }
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop, reservable: true) }

  around do |example|
    travel_to(zone.local(2026, 9, 9, 8, 0)) { example.run }
  end

  before { ActiveJob::Base.queue_adapter = :test }

  it "refreshes each affected today or tomorrow canvas when availability changes" do
    create(
      :reservation,
      member: member,
      shop: shop,
      reservation_scope: "tools",
      tool_ids: [tool.id.to_s],
      start_at: zone.local(2026, 9, 9, 23, 0),
      end_at: zone.local(2026, 9, 10, 1, 0),
      status: "approved"
    )

    expect {
      tool.update!(disabled: true)
    }.to have_enqueued_job(ReservationSlackCanvasSyncJob)
      .with(shop.id.to_s, %w[2026-09-09 2026-09-10]).exactly(:once)
  end

  it "refreshes an affected canvas when a legacy nil availability becomes disabled" do
    tool.set(disabled: nil)
    create(
      :reservation,
      member: member,
      shop: shop,
      reservation_scope: "tools",
      tool_ids: [tool.id.to_s],
      start_at: zone.local(2026, 9, 9, 9, 0),
      end_at: zone.local(2026, 9, 9, 10, 0),
      status: "approved"
    )

    expect {
      tool.update!(disabled: true)
    }.to have_enqueued_job(ReservationSlackCanvasSyncJob)
      .with(shop.id.to_s, ["2026-09-09"]).exactly(:once)
  end

  it "does not refresh reservation canvases without an affected reservation" do
    create(
      :reservation,
      member: member,
      shop: shop,
      reservation_scope: "tools",
      tool_ids: [tool.id.to_s],
      start_at: zone.local(2026, 9, 11, 9, 0),
      end_at: zone.local(2026, 9, 11, 10, 0),
      status: "approved"
    )

    expect {
      tool.update!(disabled: true)
    }.not_to have_enqueued_job(ReservationSlackCanvasSyncJob)
  end

  it "ignores whole-shop reservations that do not select the tool" do
    create(
      :reservation,
      member: member,
      shop: shop,
      reservation_scope: "shop",
      tool_ids: [],
      start_at: zone.local(2026, 9, 9, 9, 0),
      end_at: zone.local(2026, 9, 9, 10, 0),
      status: "approved"
    )

    expect {
      tool.update!(disabled: true)
    }.not_to have_enqueued_job(ReservationSlackCanvasSyncJob)
  end

  describe ".set!" do
    let(:actor) { create(:member, :admin) }

    it "marks the tool out of service and logs the change" do
      result = ToolAvailabilityService.set!(tool: tool, actor: actor, value: true)

      expect(tool.reload.out_of_service).to be true
      expect(result[:outOfService]).to be true
    end

    it "raises for a non-staff actor" do
      outsider = create(:member, :current)

      expect { ToolAvailabilityService.set!(tool: tool, actor: outsider, value: true) }
        .to raise_error(Error::Forbidden)
    end

    it "notifies holders of affected reservations when the tool goes out of service" do
      reservation = create(
        :reservation, member: member, shop: shop, reservation_scope: "tools",
        tool_ids: [tool.id.to_s], start_at: zone.local(2026, 9, 9, 23, 0),
        end_at: zone.local(2026, 9, 10, 1, 0), status: "approved"
      )

      expect {
        ToolAvailabilityService.set!(tool: tool, actor: actor, value: true)
      }.to have_enqueued_job(ToolOutageNotificationJob).with(tool.id.to_s, [reservation.id])
    end

    it "does not notify when restoring service" do
      tool.update!(out_of_service: true)

      expect {
        ToolAvailabilityService.set!(tool: tool, actor: actor, value: false)
      }.not_to have_enqueued_job(ToolOutageNotificationJob)
    end

    it "does not notify when there are no affected reservations" do
      expect {
        ToolAvailabilityService.set!(tool: tool, actor: actor, value: true)
      }.not_to have_enqueued_job(ToolOutageNotificationJob)
    end

    it "does not notify when the value is unchanged" do
      tool.update!(out_of_service: true)

      expect {
        ToolAvailabilityService.set!(tool: tool, actor: actor, value: true)
      }.not_to have_enqueued_job(ToolOutageNotificationJob)
    end
  end
end
