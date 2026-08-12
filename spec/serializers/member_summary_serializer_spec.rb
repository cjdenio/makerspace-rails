require 'rails_helper'

RSpec.describe MemberSummarySerializer do
  before do
    allow(MemberSubscriber).to receive(:send_slack_invite)
  end

  it 'includes provisioning only when the controller grants privileged visibility' do
    member = create(:member)

    privileged = ActiveModelSerializers::SerializableResource.new(
      member,
      serializer: described_class,
      adapter: :attributes,
      include_provisioning: true
    ).as_json
    unprivileged = ActiveModelSerializers::SerializableResource.new(
      member,
      serializer: described_class,
      adapter: :attributes
    ).as_json

    expect(privileged).to have_key(:provisioning)
    expect(privileged.dig(:provisioning, :slack, :status)).to eq('unknown')
    expect(unprivileged).not_to have_key(:provisioning)
  end
end
