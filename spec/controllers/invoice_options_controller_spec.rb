require 'rails_helper'

RSpec.describe InvoiceOptionsController, type: :controller do

  let(:member) { create(:member)}
  let(:rental) { create(:rental, member: member)}

  describe "GET #index" do
    it "renders json of enabled resources" do
      disabled_io = create(:invoice_option, disabled: true)
      first_io = create(:invoice_option, plan_id: "foo")
      second_io = create(:invoice_option, plan_id: nil, disabled: false)

      get :index, params: {}

      expect(response).to have_http_status(200)
      expect(response.media_type).to eq "application/json"
      parsed_response = JSON.parse(response.body)
      expect(parsed_response.first['id']).to eq(first_io.id.to_s)
      expect(parsed_response.last['id']).to eq(second_io.id.to_s)
      expect(parsed_response.count).to eq(2)
    end

    it "limits to only subscription options when requested" do 
      disabled_io = create(:invoice_option, disabled: true)
      first_io = create(:invoice_option, plan_id: "foo")
      second_io = create(:invoice_option, plan_id: nil, disabled: false)

      get :index, params: { subscription_only: true }

      expect(response).to have_http_status(200)
      expect(response.media_type).to eq "application/json"
      parsed_response = JSON.parse(response.body)
      expect(parsed_response.first['id']).to eq(first_io.id.to_s)
      expect(parsed_response.count).to eq(1)
    end

    describe "limits to type when requested" do 
      it "selects member types" do 
        first_io = create(:invoice_option, plan_id: "foo", resource_class: "rental")
        second_io = create(:invoice_option, plan_id: nil, resource_class: "member")
  
        get :index, params: { types: ["member"] }
  
        expect(response).to have_http_status(200)
        expect(response.media_type).to eq "application/json"
        parsed_response = JSON.parse(response.body)
        expect(parsed_response.first['id']).to eq(second_io.id.to_s)
        expect(parsed_response.count).to eq(1)
      end

      it "selects rental types" do 
        first_io = create(:invoice_option, plan_id: "foo", resource_class: "rental")
        second_io = create(:invoice_option, plan_id: nil, resource_class: "member")
  
        get :index, params: { types: ["rental"] }
  
        expect(response).to have_http_status(200)
        expect(response.media_type).to eq "application/json"
        parsed_response = JSON.parse(response.body)
        expect(parsed_response.first['id']).to eq(first_io.id.to_s)
        expect(parsed_response.count).to eq(1)
      end
    end
  end

  describe "GET #signup" do
    it "returns only enabled member subscription options with active promotions" do
      standard = create(:invoice_option, plan_id: "standard")
      future_promotion = create(
        :invoice_option,
        plan_id: "future-promotion",
        promotion_end_date: Time.utc(2026, 7, 28)
      )
      create(:invoice_option, plan_id: "disabled", disabled: true)
      create(:invoice_option, plan_id: nil)
      create(:invoice_option, plan_id: "")
      create(:invoice_option, plan_id: "   ")
      create(:invoice_option, plan_id: "rental", resource_class: "rental")
      create(
        :invoice_option,
        plan_id: "expired-promotion",
        promotion_end_date: Time.utc(2026, 7, 26)
      )

      travel_to(Time.find_zone!("America/New_York").local(2026, 7, 27, 12, 0, 0)) do
        get :signup, params: {}
      end

      expect(response).to have_http_status(200)
      expect(response.media_type).to eq "application/json"
      expect(JSON.parse(response.body).pluck("id")).to contain_exactly(
        standard.id.to_s,
        future_promotion.id.to_s
      )
    end

    it "keeps a promotion active through its expiration date in New York" do
      promotion = create(
        :invoice_option,
        plan_id: "last-day-promotion",
        promotion_end_date: Time.utc(2026, 7, 27)
      )

      travel_to(Time.find_zone!("America/New_York").local(2026, 7, 27, 23, 59, 59)) do
        get :signup, params: {}
      end

      parsed_response = JSON.parse(response.body)
      expect(parsed_response.count).to eq(1)
      serialized = parsed_response.first
      expect(serialized["id"]).to eq(promotion.id.to_s)
      expect(serialized["disabled"]).to be(false)
      expect(serialized["isPromotion"]).to be(true)
    end

    it "expires a promotion at midnight after its expiration date in New York" do
      create(
        :invoice_option,
        plan_id: "expired-at-midnight",
        promotion_end_date: Time.utc(2026, 7, 27)
      )

      travel_to(Time.find_zone!("America/New_York").local(2026, 7, 28, 0, 0, 0)) do
        get :signup, params: {}
      end

      expect(JSON.parse(response.body)).to be_empty
    end
  end

  describe "GET show" do
    it "Renders correct invoice option as json" do
      first_io = create(:invoice_option, plan_id: "foo")
      get :show, params: {id: first_io.to_param}, format: :json

      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(response.media_type).to eq "application/json"
      expect(parsed_response['id']).to eq(first_io.id.as_json)
    end
  end

  describe "Admin request" do 
    login_admin

    describe "GET #index" do
      it "renders all invoice options" do
        disabled_io = create(:invoice_option, disabled: true)
        first_io = create(:invoice_option, plan_id: "foo")
        second_io = create(:invoice_option, plan_id: nil, disabled: false)

        get :index, params: {}

        expect(response).to have_http_status(200)
        expect(response.media_type).to eq "application/json"
        parsed_response = JSON.parse(response.body)
        expect(parsed_response.first['id']).to eq(disabled_io.id.to_s)
        expect(parsed_response.last['id']).to eq(second_io.id.to_s)
        expect(parsed_response[1]['id']).to eq(first_io.id.to_s)
        expect(parsed_response.count).to eq(3)
      end
    end

    it "does not allow admin status to bypass signup eligibility filters" do
      eligible = create(:invoice_option, plan_id: "eligible")
      create(:invoice_option, plan_id: "disabled", disabled: true)
      create(:invoice_option, plan_id: "rental", resource_class: "rental")

      get :signup, params: {}

      expect(JSON.parse(response.body).pluck("id")).to eq([eligible.id.to_s])
    end
  end
end
