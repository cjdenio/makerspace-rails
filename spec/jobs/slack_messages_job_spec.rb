require 'rails_helper'

RSpec.describe SlackMessagesJob, type: :job do 
  include ActiveJob::TestHelper

  let(:target_id) { "slack-messages-job-#{SecureRandom.hex(8)}" }
  let(:unrelated_id) { "slack-messages-job-unrelated-#{SecureRandom.hex(8)}" }

  before(:each) do 
    clear_enqueued_jobs
    Service::SlackConnector.enque_message("Message1", nil, "#{unrelated_id}.method")
    sleep 1
    Service::SlackConnector.enque_message("Message2", nil, "#{target_id}.method")
    sleep 1
    Service::SlackConnector.enque_message("Message3", nil, "#{target_id}.method2")
  end

  after(:each) do
    keys = REDIS.keys("#{target_id}.*") + REDIS.keys("#{unrelated_id}.*")
    REDIS.del(*keys) if keys.any?
    # SlackMessagesJob has retry_on StandardError -- once a stubbed failure
    # actually raises (as it should), that enqueues a real retry job into
    # ActiveJob::TestHelper's in-memory test queue. Left uncleared, it leaks
    # into whichever later example next calls perform_enqueued_jobs (that
    # drains the whole queue, not just what it itself enqueued), causing an
    # extra, unexpected job execution against that example's own state.
    clear_enqueued_jobs
  end

  it "Dispatches slack messages from Redis cache by request_id" do
    expect_any_instance_of(Service::SlackConnector).to receive(:send_slack_messages).with(["Message2", "Message3"], nil)
    SlackMessagesJob.perform_now(target_id)
  end

  it "Removes enqueued messages when sent successfully" do
    SlackMessagesJob.perform_now(target_id)
    expect(REDIS.get("#{target_id}.method")).to be(nil)
    expect(REDIS.get("#{target_id}.method2")).to be(nil)
  end

  it "Retains enqueued messages when sent failed" do
    allow_any_instance_of(Service::SlackConnector).to receive(:send_slack_messages).and_raise("Error")
    SlackMessagesJob.perform_now(target_id)
    expect(REDIS.get("#{target_id}.method")).to be_truthy
    expect(REDIS.get("#{target_id}.method2")).to be_truthy
  end

  it "Retries failed messages" do 
    call_count = 0
    allow_any_instance_of(Service::SlackConnector).to receive(:send_slack_messages) do 
      call_count += 1
      if call_count == 1
        raise StandardError
      end
    end
    perform_enqueued_jobs do 
      SlackMessagesJob.perform_now(target_id) rescue nil
    end
    expect(REDIS.get("#{target_id}.method")).to be(nil)
    expect(REDIS.get("#{target_id}.method2")).to be(nil)
  end
end
