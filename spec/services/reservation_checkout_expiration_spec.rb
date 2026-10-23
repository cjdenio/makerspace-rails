require 'rails_helper'

RSpec.describe 'Reservation checkout expiration' do
  include ActiveSupport::Testing::TimeHelpers
  around { |example| travel_to(Time.utc(2026, 10, 19, 16)) { example.run } }
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:end_at) { Time.utc(2026, 10, 21, 4) }
  let(:attributes) do
    { title: 'Expiration boundary', shop_id: shop.id.to_s, reservation_scope: 'tools',
      tool_ids: [tool.id.to_s], start_at: end_at - 1.hour, end_at: end_at }
  end
  before do
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    create(:tool_checkout, member: member, tool: tool, expires_on: Date.new(2026, 10, 20))
  end

  it 'allows the exclusive midnight end and limits the duration preview' do
    preview = ReservationService.preview(member: member, attributes: attributes)
    expect(preview[:eligible]).to be true
    expect(preview[:maximumDurationHours]).to eq(1.0)
    later = ReservationService.preview(member: member, attributes: attributes.merge(end_at: end_at + 30.minutes))
    expect(later[:eligible]).to be false
    expect(later[:errors].join).to include(tool.name, '2026-10-20')
    expect { ReservationService.create!(member: member, attributes: attributes.merge(end_at: end_at + 30.minutes)) }
      .to raise_error(Error::UnprocessableEntity, /Checkouts must remain valid/)
  end

  %w[tool shop group].each do |source|
    it "checks expiration on #{source} prerequisites" do
      prerequisite = create(:tool, shop: shop)
      create(:tool_checkout, member: member, tool: prerequisite, expires_on: Date.new(2026, 10, 19))
      input = attributes.dup
      case source
      when 'tool' then tool.update!(reservation_prerequisite_tool_ids: [prerequisite.id.to_s])
      when 'shop'
        shop.update!(reservation_prerequisite_tool_ids: [prerequisite.id.to_s])
        input[:reservation_scope] = 'shop'
        input[:tool_ids] = []
      when 'group'
        group = ToolGroup.create!(shop: shop, name: 'Reservation kit', included_tool_ids: [tool.id.to_s],
          prerequisite_ids: [prerequisite.id.to_s], reservable: true)
        input[:tool_group_ids] = [group.id.to_s]
      end
      preview = ReservationService.preview(member: member, attributes: input)
      expect(preview[:eligible]).to be false
      expect(preview[:errors].join).to include(prerequisite.name, '2026-10-19')
      member.update!(role: 'board_member')
      expect(ReservationService.preview(member: member, attributes: input)[:eligible]).to be true
    end
  end

  it 'leaves existing bookings in place but revalidates edits' do
    booking = ReservationService.create!(member: member, attributes: attributes)
    ToolCheckout.where(member_id: member.id).update_all(expires_on: Date.new(2026, 10, 19))
    expect(Reservation.where(id: booking.id)).to exist
    expect { ReservationService.update!(reservation: booking, attributes: { title: 'Changed title' }) }
      .to raise_error(Error::UnprocessableEntity, /Checkouts must remain valid/)
  end
end
