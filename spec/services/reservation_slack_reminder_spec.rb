require "rails_helper"

RSpec.describe Service::ReservationSlackReminder do
  let(:zone) { ReservationService::ZONE }
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop, name: "Woodshop") }
  let(:tool) { create(:tool, shop: shop, name: "Planer") }

  before do
    SlackUser.create!(member: member, slack_id: "U123")
    allow(Service::SlackConnector).to receive(:schedule_slack_message)
      .and_return("Q123")
    allow(Service::SlackConnector).to receive(:delete_scheduled_slack_message)
    allow(Rails.application.config.action_mailer)
      .to receive(:default_url_options)
      .and_return(host: "http://localhost", port: 3002)
    allow(Rails.application.config.action_controller)
      .to receive(:default_url_options)
      .and_return(host: "http://localhost", port: 3002)
  end

  it "schedules a 30-minute reminder for an approved reservation 6 to 47 hours away" do
    travel_to(zone.local(2026, 7, 24, 10, 0)) do
      reservation = create(
        :reservation,
        member: member,
        shop: shop,
        reservation_scope: "tools",
        tool_ids: [tool.id.to_s],
        title: "Build cabinet",
        start_at: 24.hours.from_now,
        end_at: 26.hours.from_now,
        status: "approved"
      )

      described_class.sync!(reservation)

      expect(Service::SlackConnector).to have_received(:schedule_slack_message).with(
        channel: "U123",
        text: a_string_including(
          "Build cabinet",
          "Planer in Woodshop",
          "<http://localhost:3002/reservations|member portal>"
        ),
        post_at: reservation.start_at - 30.minutes
      )
      expect(reservation.reload.scheduled_message_id).to eq("Q123")
      expect(reservation.scheduled_message_channel_id).to eq("U123")
    end
  end

  it "schedules an 8-hour reminder when the reservation is more than 47 hours away" do
    travel_to(zone.local(2026, 7, 24, 10, 0)) do
      reservation = create(
        :reservation,
        member: member,
        shop: shop,
        start_at: 48.hours.from_now,
        end_at: 49.hours.from_now,
        status: "approved"
      )

      described_class.sync!(reservation)

      expect(Service::SlackConnector).to have_received(:schedule_slack_message).with(
        channel: "U123",
        text: anything,
        post_at: reservation.start_at - 8.hours
      )
    end
  end

  it "normalizes a duplicated URL scheme and preserves an explicit host port" do
    allow(Rails.application.config.action_mailer)
      .to receive(:default_url_options)
      .and_return(host: "http://http://localhost:3035", port: 3002)

    expect(described_class.send(:portal_reservations_url))
      .to eq("http://localhost:3035/reservations")
  end

  it "does not schedule a reminder when the reservation starts in less than 6 hours" do
    travel_to(zone.local(2026, 7, 24, 10, 0)) do
      reservation = create(
        :reservation,
        member: member,
        shop: shop,
        start_at: 5.hours.from_now,
        end_at: 6.hours.from_now,
        status: "approved"
      )

      described_class.sync!(reservation)

      expect(Service::SlackConnector).not_to have_received(:schedule_slack_message)
      expect(reservation.reload.scheduled_message_id).to be_nil
    end
  end

  it "replaces an existing reminder after an approved reservation is edited within 6 hours" do
    travel_to(zone.local(2026, 7, 24, 10, 0)) do
      reservation = create(
        :reservation,
        member: member,
        shop: shop,
        title: "Updated project",
        start_at: 5.hours.from_now,
        end_at: 6.hours.from_now,
        status: "approved",
        scheduled_message_id: "QOLD",
        scheduled_message_channel_id: "U123"
      )

      described_class.sync!(reservation)

      expect(Service::SlackConnector).to have_received(:delete_scheduled_slack_message).with(
        channel: "U123",
        scheduled_message_id: "QOLD"
      )
      expect(Service::SlackConnector).to have_received(:schedule_slack_message).with(
        channel: "U123",
        text: a_string_including("Updated project"),
        post_at: reservation.start_at - 30.minutes
      )
      expect(reservation.reload.scheduled_message_id).to eq("Q123")
    end
  end

  it "deletes and clears an existing reminder when a reservation is cancelled" do
    reservation = create(
      :reservation,
      member: member,
      shop: shop,
      status: "cancelled",
      scheduled_message_id: "QOLD",
      scheduled_message_channel_id: "UORIGINAL"
    )

    described_class.sync!(reservation)

    expect(Service::SlackConnector).to have_received(:delete_scheduled_slack_message).with(
      channel: "UORIGINAL",
      scheduled_message_id: "QOLD"
    )
    expect(reservation.reload.scheduled_message_id).to be_nil
    expect(reservation.scheduled_message_channel_id).to be_nil
  end

  it "removes an existing reminder when an edited reservation returns to pending" do
    reservation = create(
      :reservation,
      member: member,
      shop: shop,
      status: "pending",
      scheduled_message_id: "QOLD",
      scheduled_message_channel_id: "U123"
    )

    described_class.sync!(reservation)

    expect(Service::SlackConnector).to have_received(:delete_scheduled_slack_message)
    expect(Service::SlackConnector).not_to have_received(:schedule_slack_message)
  end
end
