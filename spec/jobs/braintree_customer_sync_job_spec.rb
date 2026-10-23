require "rails_helper"

RSpec.describe BraintreeCustomerSyncJob, type: :job do
  let(:member) { create(:member, customer_id: "bt-customer-123") }
  let(:gateway) { instance_double(Braintree::Gateway, customer: customer_gateway) }
  let(:customer_gateway) { double("customer_gateway") }

  before do
    allow_any_instance_of(described_class).to receive(:connect_gateway).and_return(gateway)
    allow(::Service::SlackConnector).to receive(:send_slack_message)
    allow(::Service::SlackConnector).to receive(:logs_channel).and_return("#logs")
    allow(Honeybadger).to receive(:notify) if defined?(Honeybadger)
  end

  it "does nothing when the member has no Braintree customer_id" do
    member.update!(customer_id: nil)

    expect(customer_gateway).not_to receive(:update)

    described_class.new.perform(member.id.to_s)
  end

  it "does nothing when the member no longer exists" do
    missing_id = BSON::ObjectId.new.to_s

    expect {
      described_class.new.perform(missing_id)
    }.not_to raise_error
  end

  it "syncs first name, last name, and email to Braintree" do
    expect(customer_gateway).to receive(:update).with(
      member.customer_id,
      first_name: member.firstname,
      last_name: member.lastname,
      email: member.email
    )

    described_class.new.perform(member.id.to_s)
  end

  it "alerts and re-raises when the Braintree update fails" do
    error = StandardError.new("Braintree unavailable")
    allow(customer_gateway).to receive(:update).and_raise(error)

    expect {
      described_class.new.perform(member.id.to_s)
    }.to raise_error(error)

    expect(::Service::SlackConnector).to have_received(:send_slack_message).with(
      a_string_including(member.id.to_s),
      "#logs"
    )
  end
end
