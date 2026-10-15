require "rails_helper"

RSpec.describe "Reservations API", type: :request do
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop, reservable: false) }
  let(:tool) { create(:tool, shop: shop, reservable: true) }
  let(:start_at) { 1.day.from_now.change(hour: 10, min: 0, sec: 0) }
  let(:reservation_params) do
    {
      title: "Cabinet project",
      shop_id: shop.id.to_s,
      reservation_scope: "tools",
      tool_ids: [tool.id.to_s],
      start_at: start_at.iso8601,
      end_at: (start_at + 1.hour).iso8601
    }
  end

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    ActiveJob::Base.queue_adapter = :test
    create(:tool_checkout, member: member, tool: tool)
    sign_in member
  end

  context "booking notice" do
    around do |example|
      travel_to(ReservationService::ZONE.local(2026, 9, 9, 17, 11)) { example.run }
    end

    def notice_preview(hour, minute = 0, actor: member)
      start = ReservationService::ZONE.local(2026, 9, 9, hour, minute)
      ReservationService.preview(member: member, actor: actor, attributes: reservation_params.merge(
        start_at: start.iso8601, end_at: (start + 30.minutes).iso8601
      ))
    end

    it "rounds two hours notice down to 19:00 at 17:11" do
      expect(notice_preview(17, 30)[:errors].join).to include("Minimum advance notice")
      expect(notice_preview(18, 30)[:errors].join).to include("Minimum advance notice")
      expect(notice_preview(19)[:eligible]).to eq(true)
      start = ReservationService::ZONE.local(2026, 9, 9, 18, 30)
      post "/api/reservations", params: reservation_params.merge(start_at: start.iso8601, end_at: (start + 30.minutes).iso8601)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "allows zero notice while retaining future-time validation" do
      tool.update!(minimum_advance_notice_hours: 0)
      expect(notice_preview(17, 30)[:eligible]).to eq(true)
      expect(notice_preview(17)[:errors]).to include("Start time must be in the future")
    end

    it "prohibits today's date in the shop timezone" do
      tool.update!(prohibit_same_day_reservations: true)
      expect(notice_preview(23)[:errors].join).to include("Same day reservations")
      expect(ReservationService.preview(member: member, attributes: reservation_params)[:eligible]).to eq(true)
    end

    it "uses the acting RM's shop scope for delegated bookings" do
      tool.update!(prohibit_same_day_reservations: true)
      manager = create(:member, :current, role: "resource_manager", resource_manager_shop_ids: [shop.id.to_s])
      expect(notice_preview(17, 30, actor: manager)[:eligible]).to eq(true)
      manager.update!(resource_manager_shop_ids: [])
      expect(notice_preview(17, 30, actor: manager)[:errors].join).to include("Minimum advance notice", "Same day reservations")
    end

    %w[admin board_member].each do |role|
      it "lets an acting #{role} bypass both rules" do
        tool.update!(prohibit_same_day_reservations: true)
        actor = create(:member, :current, role: role)
        expect(notice_preview(17, 30, actor: actor)[:eligible]).to eq(true)
      end
    end

    %w[shop tools].each do |scope|
      [:minimum_advance_notice_hours, :prohibit_same_day_reservations].each do |policy|
        it "rejects an earlier #{scope} start violating #{policy} in preview and save" do
          resource = scope == "shop" ? shop : tool
          resource.update!(reservable: true, minimum_advance_notice_hours: 2,
            prohibit_same_day_reservations: policy == :prohibit_same_day_reservations)
          existing = create(:reservation, member: member, shop: shop, reservation_scope: scope,
            tool_ids: scope == "tools" ? [tool.id.to_s] : [], start_at: start_at, end_at: start_at + 1.hour)
          original_start = existing.start_at
          original_end = existing.end_at
          new_start = ReservationService::ZONE.local(2026, 9, 9, policy == :minimum_advance_notice_hours ? 18 : 20, 30)
          changes = { start_at: new_start.iso8601, end_at: (new_start + 1.hour).iso8601 }
          expected_error = policy == :minimum_advance_notice_hours ? "Minimum advance notice" : "Same day reservations"

          post "/api/reservations/#{existing.id}/preview", params: changes
          expect(response).to have_http_status(:ok)
          expect(JSON.parse(response.body)["eligible"]).to eq(false)
          expect(JSON.parse(response.body)["errors"].join).to include(expected_error)
          patch "/api/reservations/#{existing.id}", params: changes
          expect(response).to have_http_status(:unprocessable_content)
          expect(JSON.parse(response.body)["message"]).to include(expected_error)
          expect(existing.reload.start_at).to eq(original_start)
          expect(existing.end_at).to eq(original_end)
        end
      end
    end

    it "allows an earlier start at the rounded notice cutoff" do
      existing = create(:reservation, member: member, shop: shop, reservation_scope: "tools",
        tool_ids: [tool.id.to_s], start_at: start_at, end_at: start_at + 1.hour)
      new_start = ReservationService::ZONE.local(2026, 9, 9, 19)
      patch "/api/reservations/#{existing.id}", params: {
        start_at: new_start.iso8601, end_at: (new_start + 1.hour).iso8601
      }
      expect(response).to have_http_status(:ok)
      expect(existing.reload.start_at).to eq(new_start)
    end

    it "preserves the managed-shop RM exception when moving a start earlier" do
      tool.update!(prohibit_same_day_reservations: true)
      manager = create(:member, :current, role: "resource_manager", resource_manager_shop_ids: [shop.id.to_s])
      existing = create(:reservation, member: member, shop: shop, reservation_scope: "tools",
        tool_ids: [tool.id.to_s], start_at: start_at, end_at: start_at + 1.hour)
      sign_in manager
      new_start = ReservationService::ZONE.local(2026, 9, 9, 17, 30)
      patch "/api/admin/reservations/#{existing.id}", params: {
        start_at: new_start.iso8601, end_at: (new_start + 1.hour).iso8601
      }
      expect(response).to have_http_status(:ok)
      expect(existing.reload.start_at).to eq(new_start)
    end

    it "passes the manager actor through delegated preview and creation" do
      tool.update!(prohibit_same_day_reservations: true)
      manager = create(:member, :current, role: "resource_manager", resource_manager_shop_ids: [shop.id.to_s])
      sign_in manager
      start = ReservationService::ZONE.local(2026, 9, 9, 17, 30)
      params = reservation_params.merge(member_id: member.id.to_s, start_at: start.iso8601, end_at: (start + 30.minutes).iso8601)
      post "/api/admin/reservations/preview", params: params
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["eligible"]).to eq(true)
      post "/api/admin/reservations", params: params
      expect(response).to have_http_status(:created)
    end
  end

  it "hides billing fields from unrelated availability viewers while preserving owner and manager access" do
    owner = create(:member, :current)
    booking = create(:reservation, member: owner, shop: shop, reservation_scope: "tools", tool_ids: [tool.id.to_s],
      start_at: start_at, end_at: start_at + 1.hour, status: "unpaid", invoice: BSON::ObjectId.new.to_s,
      fee_snapshot: [{ "amount" => 10 }], notified_at: "123.456")
    day = start_at.in_time_zone(ReservationService::ZONE).to_date.iso8601
    get "/api/reservations/availability", params: { date: day, shop_id: shop.id.to_s }
    expect(response).to have_http_status(:ok)
    row = JSON.parse(response.body).find { |item| item["id"] == booking.id.to_s }
    expect(row).not_to have_key("invoice")
    expect(row).not_to have_key("feeSnapshot")
    expect(row).not_to have_key("notifiedAt")
    [owner, create(:member, :current, role: "resource_manager", resource_manager_shop_ids: [shop.id.to_s])].each do |viewer|
      sign_in viewer
      get "/api/reservations/availability", params: { date: day, shop_id: shop.id.to_s }
      row = JSON.parse(response.body).find { |item| item["id"] == booking.id.to_s }
      expect(row["invoice"]).to eq(booking.invoice)
    end
  end

  it "previews and creates an eligible tool reservation" do
    post "/api/reservations/preview", params: reservation_params

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include(
      "eligible" => true,
      "requiresApproval" => false
    )

    post "/api/reservations", params: reservation_params

    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)).to include(
      "title" => "Cabinet project",
      "status" => "approved",
      "toolIds" => [tool.id.to_s]
    )
  end

  it "returns blackout occurrences as a top-level JSON array" do
    day = start_at.in_time_zone(ReservationService::ZONE).to_date
    blackout = create(
      :reservation_blackout,
      shop: shop,
      title: "Open House",
      recurrence: "daily",
      weekday: nil,
      start_time: "09:00",
      end_time: "12:00"
    )

    get "/api/reservations/blackouts",
      params: { date: day.iso8601, shop_id: shop.id.to_s }

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    expect(JSON.parse(response.body)).to contain_exactly(
      include(
        "blackoutId" => blackout.id.to_s,
        "title" => "Open House",
        "startAt" => be_a(String),
        "endAt" => be_a(String)
      )
    )
  end

  it "rejects tool reservations when the selected shop is disabled" do
    shop.update!(disabled: true)

    post "/api/reservations", params: reservation_params

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)["message"])
      .to include("selected tools are not reservable")
    expect(Reservation.count).to eq(0)
  end

  it "omits tools belonging to disabled shops from the reservation catalog" do
    shop.update!(disabled: true)

    get "/api/reservation_catalog"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.fetch("tools").map { |item| item.fetch("id") })
      .not_to include(tool.id.to_s)
    expect(body.fetch("shops").map { |item| item.fetch("id") })
      .not_to include(shop.id.to_s)
  end

  it "excludes the member's reservation from its update preview" do
    reservation = create(
      :reservation,
      member: member,
      shop: shop,
      reservation_scope: "tools",
      tool_ids: [tool.id.to_s],
      start_at: start_at,
      end_at: start_at + 1.hour,
      status: "approved"
    )

    post "/api/reservations/#{reservation.id}/preview", params: reservation_params

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include(
      "eligible" => true,
      "conflicts" => []
    )
  end

  it "rejects a member without the selected tool checkout" do
    ToolCheckout.where(member_id: member.id).delete_all

    post "/api/reservations", params: reservation_params

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)["message"]).to include("Missing required checkout", tool.name)
    expect(Reservation.count).to eq(0)
  end

  it "allows a pending member to reserve an allow-pending tool without already having its checkout" do
    member.update!(status: "pending", expirationTime: nil)
    tool.update!(allow_pending: true)
    ToolCheckout.where(member_id: member.id).delete_all

    post "/api/reservations", params: reservation_params

    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)["toolIds"]).to eq([tool.id.to_s])
  end

  it "hides ordinary tools and rejects their reservations for a pending member" do
    orientation = create(:tool, name: "Orientation", shop: shop, reservable: true, allow_pending: true)
    shop.update!(reservable: true)
    member.update!(status: "pending", expirationTime: nil)

    get "/api/reservation_catalog"

    expect(response).to have_http_status(:ok)
    catalog_tool_ids = JSON.parse(response.body).fetch("tools").map { |item| item.fetch("id") }
    catalog_shop = JSON.parse(response.body).fetch("shops").find { |item| item.fetch("id") == shop.id.to_s }
    expect(catalog_tool_ids).to include(orientation.id.to_s)
    expect(catalog_tool_ids).not_to include(tool.id.to_s)
    expect(catalog_shop.fetch("reservable")).to be(false)

    post "/api/reservations", params: reservation_params

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)["message"]).to include("Pending members")
  end

  it "lets an inactive member list and cancel an existing reservation but not create one" do
    reservation = create(
      :reservation,
      member: member,
      shop: shop,
      reservation_scope: "tools",
      tool_ids: [tool.id.to_s],
      start_at: start_at,
      end_at: start_at + 1.hour
    )
    member.update!(status: "inactive")

    get "/api/reservations"
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).map { |item| item["id"] }).to include(reservation.id.to_s)

    post "/api/reservations", params: reservation_params
    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)["message"]).to include("inactive or expired")

    delete "/api/reservations/#{reservation.id}"
    expect(response).to have_http_status(:ok)
    expect(reservation.reload.status).to eq("cancelled")
  end

  it "allows only an assigned RM to approve a pending reservation" do
    reservation = create(
      :reservation,
      member: member,
      shop: shop,
      reservation_scope: "tools",
      tool_ids: [tool.id.to_s],
      start_at: start_at,
      end_at: start_at + 1.hour,
      status: "pending"
    )
    assigned_rm = create(
      :member,
      :resource_manager,
      :current,
      resource_manager_shop_ids: [shop.id.to_s]
    )
    sign_out member
    sign_in assigned_rm

    post "/api/admin/reservations/#{reservation.id}/approve"

    expect(response).to have_http_status(:ok)
    expect(reservation.reload.status).to eq("approved")
  end

  it "allows an admin to create an audited reservation for an eligible active member" do
    admin = create(:member, :admin, :current)
    target = create(:member, :current)
    create(:tool_checkout, member: target, tool: tool)
    sign_out member
    sign_in admin

    post "/api/admin/reservations", params: reservation_params.merge(member_id: target.id.to_s)

    expect(response).to have_http_status(:created)
    reservation = Reservation.order_by(created_at: :desc).first
    expect(reservation.member_id).to eq(target.id)
    expect(
      AuditLog.where(
        event_type: "reservation_created_on_behalf",
        actor_id: admin.id,
        subject_id: target.id,
        resource_id: reservation.id
      ).exists?
    ).to be(true)
  end

  it "enforces the target member's prerequisites for delegated reservations" do
    admin = create(:member, :admin, :current)
    target = create(:member, :current)
    sign_out member
    sign_in admin

    post "/api/admin/reservations", params: reservation_params.merge(member_id: target.id.to_s)

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)["message"]).to include("Missing required checkout")
  end

  it "prevents an RM from creating for a member outside the RM's assigned shops" do
    other_shop = create(:shop)
    rm = create(
      :member,
      :resource_manager,
      :current,
      resource_manager_shop_ids: [other_shop.id.to_s]
    )
    target = create(:member, :current)
    create(:tool_checkout, member: target, tool: tool)
    sign_out member
    sign_in rm

    post "/api/admin/reservations", params: reservation_params.merge(member_id: target.id.to_s)

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)["message"]).to include("selected shop")
  end

  it "allows a board member to reserve for 72 hours without checkouts or conflict limits" do
    board = create(:member, :board_member, :current)
    create(
      :reservation,
      member: member,
      shop: shop,
      reservation_scope: "tools",
      tool_ids: [tool.id.to_s],
      start_at: start_at,
      end_at: start_at + 2.hours
    )
    sign_out member
    sign_in board

    post "/api/reservations", params: reservation_params.merge(
      start_at: start_at.iso8601,
      end_at: (start_at + 72.hours).iso8601
    )

    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)).to include(
      "status" => "approved",
      "memberId" => board.id.to_s
    )
    expect(
      AuditLog.where(
        event_type: "board_reservation_created",
        actor_id: board.id
      ).exists?
    ).to be(true)
  end

  it "rejects a board reservation longer than 72 hours" do
    board = create(:member, :board_member, :current)
    sign_out member
    sign_in board

    post "/api/reservations", params: reservation_params.merge(
      start_at: start_at.iso8601,
      end_at: (start_at + 72.5.hours).iso8601
    )

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)["message"]).to include("maximum duration")
  end
end
