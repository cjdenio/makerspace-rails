require 'rails_helper'

RSpec.describe 'Slack reservation checkout expiration' do
  include ActiveSupport::Testing::TimeHelpers
  around { |example| travel_to(Time.utc(2026, 10, 19, 16)) { example.run } }
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop, max_reservation_duration_hours: 48) }
  let(:tool) { create(:tool, shop: shop, max_reservation_duration_hours: 48) }
  let!(:checkout) do
    create(:tool_checkout, member: member, tool: tool, expires_on: Date.new(2026, 10, 20))
  end

  def build(**options)
    SlackReservationModal.build(shop, member, **{
      reservation_scope: 'tools', tool_ids: [tool.id.to_s],
      date: '2026-10-20', start_time: '23:00', duration: 'hours:2.0'
    }.merge(options))
  end

  def block(view, id)
    view[:blocks].find { |item| item[:block_id] == id }
  end

  it 'caps durations at exclusive Eastern midnight and uses the capped end' do
    view = build
    durations = block(view, 'duration')[:element]
    expect(durations[:options].map { |option| option[:value] }).to eq(%w[hours:0.5 hours:1.0])
    expect(durations[:initial_option][:value]).to eq('hours:1.0')
    expect(view[:submit][:text]).to eq('Reserve')
    %w[date start_time duration].each { |id| expect(block(view, id)[:dispatch_action]).to be(true) }
    preview = ReservationService.preview(member: member, attributes: {
      title: 'Boundary', shop_id: shop.id.to_s, reservation_scope: 'tools', tool_ids: [tool.id.to_s],
      start_at: Time.utc(2026, 10, 21, 3), end_at: Time.utc(2026, 10, 21, 4)
    })
    expect(preview[:eligible]).to be(true)
  end

  it 'keeps an invalid selection visible with a warning instead of offering Reserve' do
    view = build(date: '2026-10-21', start_time: '10:00')
    expect(view[:submit][:text]).to eq('Review selection')
    expect(block(view, 'duration')).to be_nil
    expect(block(view, 'reservation_policy')[:text][:text]).to include(tool.name, 'reservation end')
    expect(block(view, 'tools')[:element][:initial_options].first[:text][:text]).to include('checkout required')
  end

  it 'hides unselected tools that are not checked out through the computed end' do
    view = build(reservation_scope: 'shop', tool_ids: [], date: '2026-10-21', start_time: '10:00')
    expect(block(view, 'tools')).to be_nil
    expect(view[:submit][:text]).to eq('Reserve')
  end

  %w[shop group].each do |scope|
    it "checks #{scope} prerequisites through the end" do
      checkout.set(expires_on: nil)
      prerequisite = create(:tool, shop: shop, name: 'Safety orientation')
      prerequisite_checkout = create(:tool_checkout, member: member, tool: prerequisite,
        expires_on: Date.new(2026, 10, 20))
      options = if scope == 'shop'
        shop.set(reservation_prerequisite_tool_ids: [prerequisite.id.to_s])
        { reservation_scope: 'shop', tool_ids: [] }
      else
        group = ToolGroup.create!(shop: shop, name: 'Kit', included_tool_ids: [tool.id.to_s],
          prerequisite_ids: [prerequisite.id.to_s], reservable: true)
        { tool_ids: ["group:#{group.id}"] }
      end
      view = build(**options, date: '2026-10-21', start_time: '10:00')
      expect(view[:submit][:text]).to eq('Review selection')
      expect(block(view, 'duration')).to be_nil
      expect(block(view, 'reservation_policy')[:text][:text]).to include(prerequisite.name)

      prerequisite_checkout.set(expires_on: nil)
      expect(build(**options, date: '2026-10-21', start_time: '10:00')[:submit][:text]).to eq('Reserve')
    end
  end

  it 'retains the board exemption and non-expiring checkouts' do
    checkout.set(expires_on: nil)
    expect(build(date: '2026-10-21')[:submit][:text]).to eq('Reserve')
    checkout.set(expires_on: Date.new(2026, 10, 20))
    member.set(role: 'board_member')
    expect(build(date: '2026-10-21')[:submit][:text]).to eq('Reserve')
  end

  it 'uses calendar-day ends across the daylight-saving boundary for full-day resources' do
    checkout.set(expires_on: Date.new(2026, 11, 1))
    tool.set(reservation_full_day: true)
    view = build(date: '2026-11-01', duration: 'days:2')
    expect(block(view, 'duration')[:element][:options].map { |option| option[:value] }).to eq(['days:1'])
    expect(block(view, 'reservation_calculated_end')[:text][:text]).to include('November 2, 2026', 'EST')
  end
end
