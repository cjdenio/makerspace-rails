require "rails_helper"

RSpec.describe Service::ReservationSlackCanvas do
  let(:zone) { ReservationService::ZONE }
  let(:member) do
    create(
      :member,
      :current,
      firstname: "Ada",
      lastname: "Lovelace"
    )
  end
  let(:shop) { create(:shop, name: "Woodshop", slack_channel: "woodshop") }
  let(:tool) { create(:tool, shop: shop, name: "Planer") }

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(Service::SlackConnector).to receive(:find_channel_id)
      .with("woodshop")
      .and_return("C123")
    allow(Service::SlackConnector).to receive(:create_canvas)
      .with("Today's Woodshop Reservations")
      .and_return("FTODAY")
    allow(Service::SlackConnector).to receive(:create_canvas)
      .with("Tomorrow's Woodshop Reservations")
      .and_return("FTOMORROW")
    allow(Service::SlackConnector).to receive(:set_canvas_channel_access)
    allow(Service::SlackConnector).to receive(:set_canvas_user_access)
    allow(Service::SlackConnector).to receive(:replace_canvas)
  end

  describe ".rebuild_all!" do
    let!(:shop_with_canvases) do
      create(
        :shop,
        slack_channel: "woodshop",
        canvas_today: "FTODAY"
      )
    end
    let!(:shop_without_canvases) do
      create(:shop, slack_channel: "metalshop")
    end

    before do
      allow(described_class).to receive(:sync!)
      allow(Service::VolunteerSlackCanvas).to receive(:sync!)
    end

    it "rebuilds today and tomorrow and refreshes owners only for shops with canvases" do
      travel_to(zone.local(2026, 7, 24, 0, 0)) do
        described_class.rebuild_all!
      end

      expect(described_class).to have_received(:sync!).with(
        shop_with_canvases,
        dates: %w[2026-07-24 2026-07-25],
        sync_owner_access: true
      )
      expect(described_class).not_to have_received(:sync!).with(
        shop_without_canvases,
        any_args
      )
      expect(Service::VolunteerSlackCanvas).to have_received(:sync!)
        .with(
          shop_with_canvases,
          create_if_needed: true,
          sync_owner_access: true
        )
      expect(Service::VolunteerSlackCanvas).to have_received(:sync!)
        .with(
          shop_without_canvases,
          create_if_needed: true,
          sync_owner_access: true
        )
    end

    it "rebuilds a shop without cached canvases when a reservation enters the display window" do
      travel_to(zone.local(2026, 7, 24, 0, 0)) do
        create(
          :reservation,
          member: member,
          shop: shop_without_canvases,
          start_at: zone.local(2026, 7, 25, 9, 0),
          end_at: zone.local(2026, 7, 25, 10, 0),
          status: "approved"
        )

        described_class.rebuild_all!
      end

      expect(described_class).to have_received(:sync!).with(
        shop_without_canvases,
        dates: %w[2026-07-24 2026-07-25],
        sync_owner_access: true
      )
    end

    it "explicitly waits for Retry-After and retries a 429 response" do
      response = double(headers: { "retry-after" => "11" })
      error = Slack::Web::Api::Errors::TooManyRequestsError.new(response)
      attempts = 0
      allow(described_class).to receive(:sync!) do
        attempts += 1
        raise error if attempts == 1
      end
      allow(described_class).to receive(:sleep)
      allow($stderr).to receive(:puts)

      travel_to(zone.local(2026, 7, 24, 0, 0)) do
        described_class.rebuild_all!
      end

      expect(described_class).to have_received(:sleep).with(11)
      expect(described_class).to have_received(:sync!).twice
    end
  end

  it "creates, shares, caches, and populates today's and tomorrow's canvases" do
    travel_to(zone.local(2026, 7, 24, 8, 15)) do
      create(
        :reservation,
        member: member,
        shop: shop,
        title: "Build cabinet",
        reservation_scope: "tools",
        tool_ids: [tool.id.to_s],
        start_at: zone.local(2026, 7, 24, 9, 0),
        end_at: zone.local(2026, 7, 24, 10, 30),
        status: "approved"
      )
      create(
        :reservation,
        member: create(:member, :current),
        shop: shop,
        title: "Safety class",
        start_at: zone.local(2026, 7, 25, 13, 0),
        end_at: zone.local(2026, 7, 25, 14, 0),
        status: "pending"
      )

      described_class.sync!(
        shop,
        dates: %w[2026-07-24 2026-07-25]
      )

      expect(shop.reload).to have_attributes(
        canvas_today: "FTODAY",
        canvas_tomorrow: "FTOMORROW"
      )
      expect(Service::SlackConnector).to have_received(:set_canvas_channel_access)
        .with("FTODAY", "C123")
      expect(Service::SlackConnector).to have_received(:set_canvas_channel_access)
        .with("FTOMORROW", "C123")
      expect(Service::SlackConnector).to have_received(:replace_canvas)
        .with(
          "FTODAY",
          a_string_including(
            "Build cabinet",
            "Ada Lovelace",
            "Planer",
            "09:00-10:30",
            "Approved"
          )
        )
      expect(Service::SlackConnector).to have_received(:replace_canvas)
        .with(
          "FTOMORROW",
          a_string_including("Safety class", "Entire shop", "Pending")
        )
    end
  end

  it "creates a canvas for a blackout-only day without a member or link" do
    travel_to(zone.local(2026, 7, 27, 8, 0)) do
      create(
        :reservation_blackout,
        shop: shop,
        title: "Open House",
        recurrence: "weekly",
        weekday: 1,
        start_time: "17:00",
        end_time: "20:00"
      )

      described_class.sync!(shop, dates: ["2026-07-27"])

      expect(Service::SlackConnector).to have_received(:replace_canvas).with(
        "FTODAY",
        a_string_including(
          "| 17:00-20:00 | No Reservations Available: Open House |  | Entire shop | Unavailable |"
        )
      )
      expect(Service::SlackConnector).not_to have_received(:replace_canvas)
        .with("FTODAY", a_string_including("[Open House]"))
    end
  end

  it "grants canvas ownership to admins, board members, and assigned resource managers" do
    admin = create(:member, :admin)
    board = create(:member, :board_member)
    assigned_rm = create(
      :member,
      :resource_manager,
      resource_manager_shop_ids: [shop.id.to_s]
    )
    unrelated_rm = create(
      :member,
      :resource_manager,
      resource_manager_shop_ids: [create(:shop).id.to_s]
    )
    {
      admin => "UADMIN",
      board => "UBOARD",
      assigned_rm => "URM",
      unrelated_rm => "UOTHER"
    }.each do |privileged_member, slack_id|
      SlackUser.create!(member: privileged_member, slack_id: slack_id)
    end

    travel_to(zone.local(2026, 7, 24, 8, 15)) do
      described_class.sync!(shop, dates: ["2026-07-24"])
    end

    expect(Service::SlackConnector).to have_received(:set_canvas_user_access)
      .with(
        "FTODAY",
        a_collection_containing_exactly("UADMIN", "UBOARD", "URM"),
        access_level: "owner"
      )
  end

  it "sets a member to owner or read on both shop canvases based on current RM assignment" do
    shop.update!(
      canvas_today: "FTODAY-EXISTING",
      canvas_tomorrow: "FTOMORROW-EXISTING",
      volunteer_canvas_id: "FVOLUNTEER-EXISTING"
    )
    rm = create(
      :member,
      :resource_manager,
      resource_manager_shop_ids: [shop.id.to_s]
    )
    SlackUser.create!(member: rm, slack_id: "URM")

    described_class.sync_member_access!(rm, shop_ids: [shop.id.to_s])

    expect(Service::SlackConnector).to have_received(:set_canvas_user_access)
      .with("FTODAY-EXISTING", ["URM"], access_level: "owner")
    expect(Service::SlackConnector).to have_received(:set_canvas_user_access)
      .with("FTOMORROW-EXISTING", ["URM"], access_level: "owner")
    expect(Service::SlackConnector).to have_received(:set_canvas_user_access)
      .with("FVOLUNTEER-EXISTING", ["URM"], access_level: "owner")

    rm.update!(role: "member", resource_manager_shop_ids: [])
    described_class.sync_member_access!(rm, shop_ids: [shop.id.to_s])

    expect(Service::SlackConnector).to have_received(:set_canvas_user_access)
      .with("FTODAY-EXISTING", ["URM"], access_level: "read")
    expect(Service::SlackConnector).to have_received(:set_canvas_user_access)
      .with("FTOMORROW-EXISTING", ["URM"], access_level: "read")
    expect(Service::SlackConnector).to have_received(:set_canvas_user_access)
      .with("FVOLUNTEER-EXISTING", ["URM"], access_level: "read")
  end

  it "reapplies the complete owner list when rebuilding an existing canvas" do
    shop.update!(canvas_today: "FTODAY-EXISTING")
    admin = create(:member, :admin)
    SlackUser.create!(member: admin, slack_id: "UADMIN")

    travel_to(zone.local(2026, 7, 24, 0, 0)) do
      described_class.sync!(
        shop,
        dates: ["2026-07-24"],
        sync_owner_access: true
      )
    end

    expect(Service::SlackConnector).to have_received(:set_canvas_user_access)
      .with("FTODAY-EXISTING", ["UADMIN"], access_level: "owner")
  end

  it "reuses a cached canvas ID instead of creating another canvas" do
    travel_to(zone.local(2026, 7, 24, 8, 15)) do
      shop.update!(canvas_today: "FEXISTING")

      described_class.sync!(shop, dates: ["2026-07-24"])

      expect(Service::SlackConnector).not_to have_received(:create_canvas)
        .with("Today's Woodshop Reservations")
      expect(Service::SlackConnector).to have_received(:replace_canvas)
        .with("FEXISTING", a_string_including("No pending or approved reservations"))
    end
  end

  it "recreates a cached canvas that no longer exists in Slack" do
    travel_to(zone.local(2026, 7, 24, 8, 15)) do
      shop.update!(canvas_today: "FDELETED")
      attempts = 0
      allow(Service::SlackConnector).to receive(:set_canvas_channel_access) do
        attempts += 1
        if attempts == 1
          raise Slack::Web::Api::Errors::CanvasNotFound.new("canvas_not_found")
        end
      end

      described_class.sync!(shop, dates: ["2026-07-24"])

      expect(shop.reload.canvas_today).to eq("FTODAY")
      expect(Service::SlackConnector).to have_received(:create_canvas)
        .with("Today's Woodshop Reservations")
      expect(Service::SlackConnector).to have_received(:replace_canvas)
        .with("FTODAY", a_string_including("Woodshop Reservations"))
    end
  end

  it "logs the configured channel when it cannot be resolved" do
    allow(Service::SlackConnector).to receive(:find_channel_id).and_return(nil)
    expect(Rails.logger).to receive(:error).with(
      a_string_including(
        "[ReservationSlackCanvasChannelNotFound]",
        "shop_id=#{shop.id}",
        'slack_channel="woodshop"'
      )
    )

    described_class.sync!(shop, dates: [Date.current])

    expect(Service::SlackConnector).not_to have_received(:create_canvas)
  end

  it "logs canvas creation and writing successes to stderr" do
    travel_to(zone.local(2026, 7, 24, 8, 15)) do
      expect {
        described_class.sync!(shop, dates: ["2026-07-24"])
      }.to output(
        a_string_including(
          "[ReservationSlackCanvas] create_start",
          'slack_channel="woodshop"',
          "title=\"Today's Woodshop Reservations\"",
          "[ReservationSlackCanvas] create_success",
          "canvas_id=FTODAY",
          "[ReservationSlackCanvas] access_success",
          "[ReservationSlackCanvas] write_start",
          "[ReservationSlackCanvas] write_success",
          "date=2026-07-24"
        )
      ).to_stderr
    end
  end

  it "logs canvas writing failures to stderr before reraising" do
    travel_to(zone.local(2026, 7, 24, 8, 15)) do
      shop.update!(canvas_today: "FEXISTING")
      error = Slack::Web::Api::Errors::CanvasEditingFailed.new(
        "canvas editing failed\nwith details"
      )
      allow(Service::SlackConnector).to receive(:replace_canvas).and_raise(error)

      expect {
        expect {
          described_class.sync!(shop, dates: ["2026-07-24"])
        }.to raise_error(Slack::Web::Api::Errors::CanvasEditingFailed)
      }.to output(
        a_string_including(
          "[ReservationSlackCanvas] write_failure",
          'slack_channel="woodshop"',
          "canvas_id=FEXISTING",
          "date=2026-07-24",
          "CanvasEditingFailed: canvas editing failed with details"
        )
      ).to_stderr
    end
  end

  it "logs canvas creation failures to stderr before reraising" do
    travel_to(zone.local(2026, 7, 24, 8, 15)) do
      error = Slack::Web::Api::Errors::CanvasCreationFailed.new(
        "canvas creation failed\nwith details"
      )
      allow(Service::SlackConnector).to receive(:create_canvas).and_raise(error)

      expect {
        expect {
          described_class.sync!(shop, dates: ["2026-07-24"])
        }.to raise_error(Slack::Web::Api::Errors::CanvasCreationFailed)
      }.to output(
        a_string_including(
          "[ReservationSlackCanvas] create_start",
          'slack_channel="woodshop"',
          "field=canvas_today",
          "[ReservationSlackCanvas] create_failure",
          "CanvasCreationFailed: canvas creation failed with details"
        )
      ).to_stderr
    end
  end
end
