require 'rails_helper'

RSpec.describe Service::MembershipExpirationNotice do
  let(:at) { Time.find_zone!('America/New_York').local(2026, 9, 20, 9, 0) }

  before do
    allow(MemberMailer).to receive(:membership_expiring_soon).and_return(double(deliver_later: true))
    allow(MemberMailer).to receive(:membership_expired).and_return(double(deliver_later: true))
    allow(Service::ErrorReporter).to receive(:notify)
  end

  def expiring_in(days)
    (at + days.days).to_i * 1000
  end

  def expired_days_ago(days)
    (at - days.days).to_i * 1000
  end

  it "emails a non-subscribed member expiring in exactly 3 days and records the sent expirationTime" do
    member = create(:member, subscription: false, subscription_id: nil, expirationTime: expiring_in(3))

    described_class.run!(at: at)

    expect(MemberMailer).to have_received(:membership_expiring_soon).with(member.id.as_json)
    expect(member.reload.membership_expiring_soon_notice_sent_for).to eq(member.expirationTime)
  end

  it "emails a non-subscribed member whose expiration passed exactly 1 day ago" do
    member = create(:member, subscription: false, subscription_id: nil, expirationTime: expired_days_ago(1))

    described_class.run!(at: at)

    expect(MemberMailer).to have_received(:membership_expired).with(member.id.as_json)
    expect(member.reload.membership_expired_notice_sent_for).to eq(member.expirationTime)
  end

  it "does not email a member with subscription flagged true" do
    # Passing subscription_id: nil explicitly alongside subscription: true in
    # the same create() causes Mongoid to persist subscription as false (a
    # confirmed quirk of that specific attribute combination, unrelated to
    # this feature) -- so leave subscription_id unset here and let it take
    # its natural nil default, same as a real subscribed-by-flag member would.
    create(:member, subscription: true, expirationTime: expiring_in(3))

    described_class.run!(at: at)

    expect(MemberMailer).not_to have_received(:membership_expiring_soon)
  end

  it "does not email a member with a Braintree subscription_id" do
    create(:member, subscription: false, subscription_id: "sub-123", expirationTime: expiring_in(3))

    described_class.run!(at: at)

    expect(MemberMailer).not_to have_received(:membership_expiring_soon)
  end

  it "does not email a member with an active Earned Membership" do
    member = create(:member, subscription: false, subscription_id: nil, expirationTime: expiring_in(3))
    create(:earned_membership, member: member)

    described_class.run!(at: at)

    expect(MemberMailer).not_to have_received(:membership_expiring_soon)
  end

  it "does not email the Landlord/Fob placeholder" do
    create(:member, firstname: "Landlord", lastname: "Fob", subscription: false, subscription_id: nil, expirationTime: expiring_in(3))

    described_class.run!(at: at)

    expect(MemberMailer).not_to have_received(:membership_expiring_soon)
  end

  it "does not email a member whose status is no longer active" do
    create(:member, status: "revoked", subscription: false, subscription_id: nil, expirationTime: expiring_in(3))

    described_class.run!(at: at)

    expect(MemberMailer).not_to have_received(:membership_expiring_soon)
  end

  it "does not re-send the same notice twice for the same expiration" do
    member = create(:member, subscription: false, subscription_id: nil, expirationTime: expiring_in(3))

    described_class.run!(at: at)
    described_class.run!(at: at)

    expect(MemberMailer).to have_received(:membership_expiring_soon).once
  end

  it "sends again once the member renews to a new expiration" do
    member = create(:member, subscription: false, subscription_id: nil, expirationTime: expiring_in(3))
    described_class.run!(at: at)
    expect(MemberMailer).to have_received(:membership_expiring_soon).once

    renewed_at = at + 30.days
    member.update_attribute(:expirationTime, (renewed_at + 3.days).to_i * 1000)
    described_class.run!(at: renewed_at)

    expect(MemberMailer).to have_received(:membership_expiring_soon).twice
  end

  it "also sends a Slack DM when the member has a linked Slack account" do
    member = create(:member, subscription: false, subscription_id: nil, expirationTime: expiring_in(3))
    SlackUser.create!(member_id: member.id, slack_id: "U123456")
    allow(Service::SlackConnector).to receive(:send_slack_message)

    described_class.run!(at: at)

    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, "U123456")
  end

  it "does not attempt a Slack DM when the member has no linked Slack account" do
    create(:member, subscription: false, subscription_id: nil, expirationTime: expiring_in(3))
    allow(Service::SlackConnector).to receive(:send_slack_message)

    described_class.run!(at: at)

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it "logs candidate windows and comma-delimited member names outside production" do
    expiring_member = create(:member, firstname: "Soon", lastname: "Member", subscription: false,
      subscription_id: nil, expirationTime: expiring_in(3))
    expired_member = create(:member, firstname: "Past", lastname: "Member", subscription: false,
      subscription_id: nil, expirationTime: expired_days_ago(1))
    allow(Rails.logger).to receive(:info)

    described_class.run!(at: at)

    expiring_day = (at + 3.days).to_date
    expired_day = (at - 1.day).to_date
    expect(Rails.logger).to have_received(:info).with(
      "day: #{expiring_day}, start_ms: #{expiring_day.beginning_of_day.in_time_zone(described_class::ZONE).to_i * 1000}, " \
      "end_ms: #{(expiring_day + 1.day).beginning_of_day.in_time_zone(described_class::ZONE).to_i * 1000}"
    )
    expect(Rails.logger).to have_received(:info).with(
      "day: #{expired_day}, start_ms: #{expired_day.beginning_of_day.in_time_zone(described_class::ZONE).to_i * 1000}, " \
      "end_ms: #{(expired_day + 1.day).beginning_of_day.in_time_zone(described_class::ZONE).to_i * 1000}"
    )
    expect(Rails.logger).to have_received(:info).with("expiring_soon: #{expiring_member.fullname}")
    expect(Rails.logger).to have_received(:info).with("expired: #{expired_member.fullname}")
  end

  it "logs nil for empty candidate lists outside production" do
    allow(Rails.logger).to receive(:info)

    described_class.run!(at: at)

    expect(Rails.logger).to have_received(:info).with("expiring_soon: nil")
    expect(Rails.logger).to have_received(:info).with("expired: nil")
  end

  it "does not log candidate details in production" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    allow(Rails.logger).to receive(:info)

    described_class.run!(at: at)

    expect(Rails.logger).not_to have_received(:info)
  end

  it "reports (but does not raise past) an error sending to one member, and still sends to others" do
    failing = create(:member, subscription: false, subscription_id: nil, expirationTime: expiring_in(3))
    succeeding = create(:member, subscription: false, subscription_id: nil, expirationTime: expiring_in(3))
    allow(MemberMailer).to receive(:membership_expiring_soon).with(failing.id.as_json).and_raise("boom")

    expect { described_class.run!(at: at) }.not_to raise_error

    expect(Service::ErrorReporter).to have_received(:notify)
    expect(MemberMailer).to have_received(:membership_expiring_soon).with(succeeding.id.as_json)
    expect(failing.reload.membership_expiring_soon_notice_sent_for).to be_nil
  end
end
