require 'rails_helper'

RSpec.describe MemberSerializer do
  let(:member) { create(:member) }

  before do
    allow(Service::CardExpirationCheck).to receive(:card_types_for_member)
      .with(member.id).and_return('Visa')
  end

  def serialize(viewer)
    ActiveModelSerializers::SerializableResource.new(
      member,
      serializer: described_class,
      adapter: :attributes,
      viewer: viewer
    ).as_json
  end

  it 'includes expiring cards for a board member viewing another profile' do
    expect(serialize(create(:member, :board_member))[:expiringPaymentCardTypes]).to eq('Visa')
  end

  it 'does not include expiring cards for a resource manager viewing another profile' do
    expect(serialize(create(:member, :resource_manager))).not_to have_key(:expiringPaymentCardTypes)
  end
end
