require 'rails_helper'
require 'rake'

RSpec.describe 'invoice_review' do
  let(:task) { Rake::Task['invoice_review'] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('invoice_review')
    task.reenable
  end

  after { task.reenable }

  it "reports a deleted member instead of crashing (Mongoid raise_not_found_error is false)" do
    member = create(:member)
    create(:invoice, member: member, resource_id: member.id, transaction_id: "txn_123", settled_at: nil)
    member_id = member.id
    member.destroy

    sent_messages = nil
    allow(::Service::SlackConnector).to receive(:send_slack_messages) { |messages, _channel| sent_messages = messages }

    expect { task.invoke }.not_to raise_error

    expect(sent_messages.join("\n")).to include("(deleted member #{member_id})")
  end
end
