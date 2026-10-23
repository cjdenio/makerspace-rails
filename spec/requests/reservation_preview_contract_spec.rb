require "swagger_helper"
require "json-schema"

RSpec.describe "Reservation preview fee contract", type: :request do
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop, reservable: true, max_reservation_duration_hours: 24) }
  let(:schemas) do
    source = JSON.parse(RSpec.configuration.openapi_specs.values.first[:components][:schemas][:ReservationPreview].to_json)
    published = JSON.parse(File.read(Rails.root.join("swagger/v1/swagger.json"))).dig("components", "schemas", "ReservationPreview")
    expect(published).to eq(source)
    [source, published]
  end

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    ActiveJob::Base.queue_adapter = :test
    sign_in member
  end

  [false, true].each do |charged|
    it "validates a #{charged ? 'paid' : 'free'} preview against source and published schemas" do
      if charged
        option = InvoiceOption.create!(name: "Extended", amount: 10, quantity: 1, resource_class: "fee")
        shop.update!(duration_fees: [{ invoice_option_id: option.id.to_s, minimum_hours: 4, maximum_hours: 4 }])
      end
      start_at = 2.days.from_now.change(hour: 10, min: 0, sec: 0)
      input = { title: "Contract test", shop_id: shop.id.to_s, reservation_scope: "shop", tool_ids: [],
        start_at: start_at.iso8601, end_at: (start_at + 4.hours).iso8601 }
      post "/api/reservations/preview", params: input, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["eligible"]).to eq(true), body.inspect
      schemas.each { |schema| expect(JSON::Validator.fully_validate(schema, body)).to eq([]) }
      expect(body["feeTotal"]).to eq(charged ? 10 : 0)
      expect(body["feeLines"].length).to eq(charged ? 1 : 0)
      expect(body["feeConfirmation"]).to be_a(String)
      post "/api/reservations", params: input.merge(feeConfirmation: body.fetch("feeConfirmation")), as: :json
      expect(response).to have_http_status(:created), response.body
    end
  end
  def verify_fields(schema_name, payload, fields)
    source = JSON.parse(RSpec.configuration.openapi_specs.values.first[:components][:schemas][schema_name].to_json)
    published = JSON.parse(File.read(Rails.root.join("swagger/v1/swagger.json"))).dig("components", "schemas", schema_name.to_s)
    expect(published).to eq(source)
    fields.each { |field| expect(source.fetch("properties")).to have_key(field) }
    schema = source.merge("properties" => source.fetch("properties").slice(*fields), "required" => fields)
    # JSON::Validator uses JSON Schema rather than OpenAPI's nullable extension.
    schema["properties"].each_value do |property|
      property["type"] = [property["type"], "null"] if property["nullable"]
    end
    expect(JSON::Validator.fully_validate(schema, payload)).to eq([])
  end

  it "publishes duration fees and policies serialized for both shops and tools" do
    option = InvoiceOption.create!(name: "Extended", amount: 10, quantity: 1, resource_class: "fee")
    rules = [
      { invoice_option_id: option.id.to_s, minimum_hours: 4, maximum_hours: 4, full_day: false },
      { invoice_option_id: option.id.to_s, full_day: true }
    ]
    tool = create(:tool, shop: shop)
    [shop, tool].each do |resource|
      resource.update!(minimum_advance_notice_hours: 0, prohibit_same_day_reservations: true,
        reservation_full_day: true, max_reservation_duration_hours: 48, duration_fees: rules.deep_dup)
      payload = JSON.parse(ActiveModelSerializers::SerializableResource.new(resource, scope: member, adapter: :attributes, key_transform: :camel_lower).to_json)
      verify_fields(:ReservationResourceConfig, payload,
        %w[minimumAdvanceNoticeHours prohibitSameDayReservations reservationFullDay durationFees])
      expect(payload["durationFees"].first["invoiceOptionId"]).to eq(option.id.to_s)
      resource.reload
    end
  end

  it "publishes reservation mode and optional owner billing fields, including null values" do
    reservation = create(:reservation, member: member, shop: shop, reservation_scope: "shop", tool_ids: [])
    [false, true].each do |charged|
      reservation.set(full_day: charged, invoice: charged ? BSON::ObjectId.new.to_s : nil,
        notified_at: charged ? "123.456" : nil,
        fee_snapshot: charged ? [{ resourceId: shop.id.to_s, resourceName: shop.name,
          invoiceOptionId: BSON::ObjectId.new.to_s, name: "Extended", unitHours: 24, units: 1, unitAmount: 10, amount: 10 }] : [])
      payload = JSON.parse(ActiveModelSerializers::SerializableResource.new(reservation, scope: member, adapter: :attributes, key_transform: :camel_lower).to_json)
      verify_fields(:Reservation, payload, %w[fullDay invoice feeSnapshot notifiedAt])
    end
    payload = JSON.parse(ActiveModelSerializers::SerializableResource.new(reservation, scope: nil, adapter: :attributes, key_transform: :camel_lower).to_json)
    expect(payload.keys).not_to include("invoice", "feeSnapshot", "notifiedAt")
    schema = RSpec.configuration.openapi_specs.values.first[:components][:schemas][:Reservation]
    expect(schema[:required]).not_to include(:invoice, :feeSnapshot, :notifiedAt)
  end

end
