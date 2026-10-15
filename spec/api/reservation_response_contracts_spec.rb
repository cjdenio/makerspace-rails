require 'swagger_helper'

RSpec.describe 'Reservation response contracts', type: :request do
  let(:member) { create(:member, :admin, :current) }
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop, reservable: true) }
  let(:booking) { create(:reservation, member: member, shop: shop, reservation_scope: 'tools', tool_ids: [tool.id.to_s], start_at: 3.days.from_now, end_at: 3.days.from_now + 1.hour) }
  let(:id) { booking.id.to_s }
  let(:booking_start) { 5.days.from_now.change(hour: 10, min: 0, sec: 0) }
  let(:body) { { title: 'Workshop project', member_id: member.id.to_s, shop_id: shop.id.to_s, reservation_scope: 'tools', tool_ids: [tool.id.to_s], start_at: booking_start.iso8601, end_at: (booking_start + 1.hour).iso8601 } }
  before do
    create(:tool_checkout, member: member, tool: tool)
    sign_in member
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end

  ['/reservations', '/admin/reservations'].each do |route|
    path route do
      get 'List authorized reservations with resource availability warnings' do
        tags 'Reservations'
        security [sessionAuth: []]
        produces 'application/json'
        %w[shop_id status start_at end_at].each { |key| parameter name: key, in: :query, required: false, type: :string }
        response '200', 'Authorized reservations; existing bookings remain present during outages' do
          schema type: :array, items: { '$ref' => '#/components/schemas/Reservation' }
          before { booking; tool.set(out_of_service: true) }
          run_test! do |response|
            expect(JSON.parse(response.body).first.fetch('outOfServiceToolNames')).to eq([tool.name])
          end
        end
      end
      post 'Create a reservation' do
        tags 'Reservations'
        security [sessionAuth: []]
        consumes 'application/json'
        produces 'application/json'
        parameter name: :body, in: :body, schema: { '$ref' => '#/components/schemas/ReservationWrite' }
        response '201', 'Created reservation' do
          schema '$ref' => '#/components/schemas/Reservation'
          run_test!
        end
        response '422', 'Invalid reservation, including selecting an out-of-service tool' do
          schema '$ref' => '#/components/schemas/ReservationError'
          before { tool.set(out_of_service: true) }
          run_test! { |response| expect(JSON.parse(response.body)['message']).to include('out of service') }
        end
      end
    end
    path "#{route}/{id}" do
      parameter name: :id, in: :path, type: :string
      [:patch, :put].each do |verb|
        public_send(verb, 'Update a reservation') do
          tags 'Reservations'
          security [sessionAuth: []]
          consumes 'application/json'
          produces 'application/json'
          parameter name: :body, in: :body, schema: { '$ref' => '#/components/schemas/ReservationWrite' }
          response '200', 'Updated reservation' do
            schema '$ref' => '#/components/schemas/Reservation'
            run_test!
          end
          response '422', 'Invalid reservation, including adding or rescheduling an out-of-service tool' do
            schema '$ref' => '#/components/schemas/ReservationError'
            before { booking; tool.set(out_of_service: true) }
            run_test! { |response| expect(JSON.parse(response.body)['message']).to include('out of service') }
          end
        end
      end
      delete 'Cancel a reservation, preserving resource availability warnings' do
        tags 'Reservations'
        security [sessionAuth: []]
        produces 'application/json'
        response '200', 'Cancelled reservation' do
          schema '$ref' => '#/components/schemas/Reservation'
          run_test!
        end
      end
    end
  end
  path '/reservations/availability' do
    get 'List visible reservations and availability warnings' do
      tags 'Reservations'
      security [sessionAuth: []]
      produces 'application/json'
      parameter name: :date, in: :query, type: :string, required: true
      parameter name: :shop_id, in: :query, type: :string, required: false
      let(:date) { Date.current.iso8601 }
      response '200', 'Reservations in the requested time range' do
        schema type: :array, items: { '$ref' => '#/components/schemas/Reservation' }
        run_test!
      end
    end
  end
  %w[approve deny].each do |action|
    path "/admin/reservations/{id}/#{action}" do
      parameter name: :id, in: :path, type: :string
      post "#{action.capitalize} a reservation" do
        tags 'Reservations'
        security [sessionAuth: []]
        consumes 'application/json'
        produces 'application/json'
        parameter name: :body, in: :body, schema: { type: :object, properties: { decision_note: { type: :string } } }
        let(:body) { { decision_note: 'Reviewed booking' } }
        before do
          booking.set(status: 'pending')
          sign_in create(:member, :admin, :current)
        end
        response '200', 'Reservation with availability warnings' do
          schema '$ref' => '#/components/schemas/Reservation'
          run_test!
        end
      end
    end
  end

end
