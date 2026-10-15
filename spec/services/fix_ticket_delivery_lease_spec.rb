require 'rails_helper'
RSpec.describe FixTicketDeliveryLease do
  it 'stops Slack access after ownership is lost' do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(0)
    expect(Service::SlackConnector).not_to receive(:client)
    expect do
      described_class.with('test-ticket') { FixTicketDelivery.client }
    end.to raise_error(Error::Conflict)
    expect(Thread.current[:fix_delivery_lease]).to be_nil
  end
  it 'does not start a second delivery while the ticket is leased' do
    allow(REDIS).to receive(:set).and_return(false)
    ran = false
    expect { described_class.with('test-ticket') { ran = true } }.to raise_error(Error::Conflict)
    expect(ran).to be(false)
  end
end
