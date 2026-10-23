require 'rails_helper'

RSpec.describe MailtrapCustomVariableInterceptor do
  it "tags the outgoing message with its own message_id as a custom variable" do
    message = Mail::Message.new
    message.to = 'someone@example.com'
    message.subject = 'Hello'
    message.message_id = 'abc123@example.com'

    described_class.delivering_email(message)

    variables = JSON.parse(message['X-MT-Custom-Variables'].value)
    expect(variables['app_message_id']).to eq('abc123@example.com')
  end

  it "does nothing when the message has no message_id" do
    message = Mail::Message.new
    message.to = 'someone@example.com'
    message.subject = 'Hello'
    allow(message).to receive(:message_id).and_return(nil)

    expect { described_class.delivering_email(message) }.not_to raise_error
    expect(message['X-MT-Custom-Variables']).to be_nil
  end
end
