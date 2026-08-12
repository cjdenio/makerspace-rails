require "rails_helper"

RSpec.describe Service::ReservationCalendar do
  let(:member) { create(:member, :current, email: "member@example.com") }
  let(:shop) do
    create(
      :shop,
      name: "Woodshop",
      color_id: "7",
      resource_email: "woodshop-resource@example.com"
    )
  end
  let(:tool) do
    create(
      :tool,
      shop: shop,
      name: "Planer",
      resource_email: "planer-resource@example.com"
    )
  end
  let(:reservation) do
    create(
      :reservation,
      member: member,
      shop: shop,
      reservation_scope: "tools",
      tool_ids: [tool.id.to_s]
    )
  end

  it "adds the shop color, shop label, owner attendee, and tool-in-shop description" do
    create(:mailtrap_event, member: member, email: member.email, status: "delivery")

    event = described_class.send(:build_event, reservation)

    expect(event.color_id).to eq("7")
    expect(event.event_label_id).to eq(Service::GoogleWorkspace.label_id_for(shop.id))
    expect(event.description).to include("Resources: Planer in Woodshop")
    expect(event.extended_properties.private["makerspace_shop_id"]).to eq(shop.id.to_s)
    expect(event.attendees).to include(
      have_attributes(email: tool.resource_email, resource: true),
      have_attributes(email: member.email)
    )
  end

  it "does not invite an owner whose latest delivery status is undeliverable" do
    create(:mailtrap_event, member: member, email: member.email, status: "bounce")

    event = described_class.send(:build_event, reservation)

    expect(event.attendees.map(&:email)).not_to include(member.email)
  end

  it "derives a stable UUID label ID from the Mongo ObjectID" do
    first = Service::GoogleWorkspace.label_id_for(shop.id)
    second = Service::GoogleWorkspace.label_id_for(shop.id)

    expect(first).to eq(second)
    expect(first).to match(
      /\A[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    )
  end

  it "persists the Google event ID and HTML link returned by Calendar" do
    result = double(
      id: reservation.id.to_s,
      html_link: "https://calendar.google.com/calendar/event?eid=example"
    )
    allow(Service::GoogleWorkspace).to receive(:reservations_calendar_id)
      .and_return("reservations@example.com")
    allow(described_class).to receive(:upsert_event).and_return(result)

    described_class.sync!(reservation)

    reservation.reload
    expect(reservation.calendar_event_id).to eq(reservation.id.to_s)
    expect(reservation.calendar_html_link).to eq(result.html_link)
    expect(reservation.calendar_sync_status).to eq("synced")
  end

  describe "invalid event label recovery" do
    let(:calendar_id) { "reservations@example.com" }
    let(:event) { described_class.send(:build_event, reservation) }
    let(:invalid_label_error) do
      Google::Apis::ClientError.new(
        "invalid: Invalid event label",
        status_code: 400
      )
    end
    let(:result) { double(id: reservation.id.to_s) }

    it "recreates the shop label and retries the labeled event" do
      attempts = 0
      allow(Service::GoogleWorkspace).to receive(:insert_labeled_event) do
        attempts += 1
        raise invalid_label_error if attempts == 1

        result
      end
      allow(Service::GoogleWorkspace).to receive(:ensure_label!).and_return(true)
      allow(Service::GoogleWorkspace).to receive(:insert_event)

      response = described_class.send(
        :write_event_with_label_recovery,
        calendar_id,
        event,
        reservation
      )

      expect(response).to eq(result)
      expect(Service::GoogleWorkspace).to have_received(:ensure_label!).with(shop).once
      expect(Service::GoogleWorkspace).to have_received(:insert_labeled_event).twice
      expect(Service::GoogleWorkspace).not_to have_received(:insert_event)
    end

    it "falls back to an unlabeled event when recreating the label fails" do
      fallback_event = nil
      allow(Service::GoogleWorkspace).to receive(:insert_labeled_event)
        .and_raise(invalid_label_error)
      allow(Service::GoogleWorkspace).to receive(:ensure_label!)
        .and_raise(StandardError, "label creation failed")
      allow(Service::GoogleWorkspace).to receive(:insert_event) do |_calendar, event_arg, **_|
        fallback_event = event_arg
        result
      end

      response = described_class.send(
        :write_event_with_label_recovery,
        calendar_id,
        event,
        reservation
      )

      expect(response).to eq(result)
      expect(fallback_event.event_label_id).to be_nil
      expect(fallback_event.extended_properties.private).not_to have_key(
        "makerspace_label_id"
      )
    end

    it "falls back to an unlabeled event when the labeled retry fails" do
      attempts = 0
      allow(Service::GoogleWorkspace).to receive(:insert_labeled_event) do
        attempts += 1
        raise invalid_label_error if attempts == 1
        raise Google::Apis::ServerError.new("retry failed", status_code: 500)
      end
      allow(Service::GoogleWorkspace).to receive(:ensure_label!).and_return(true)
      allow(Service::GoogleWorkspace).to receive(:insert_event).and_return(result)

      response = described_class.send(
        :write_event_with_label_recovery,
        calendar_id,
        event,
        reservation
      )

      expect(response).to eq(result)
      expect(Service::GoogleWorkspace).to have_received(:insert_labeled_event).twice
      expect(Service::GoogleWorkspace).to have_received(:insert_event).once
    end
  end
end
