require 'rails_helper'

RSpec.describe CheckoutExpirationNotice do
  include ActiveSupport::Testing::TimeHelpers
  let(:member) { create(:member, :current) }
  let(:today) { Date.new(2026, 10, 19) }
  let(:delivery) { double(deliver_now: true) }
  around { |example| travel_to(Time.utc(2026, 10, 19, 16)) { example.run } }
  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(Service::ErrorReporter).to receive(:notify)
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(CheckoutMailer).to receive(:expiration_notice).and_return(delivery)
    allow(ToolCheckoutSlackCanvasSyncJob).to receive(:perform_later).and_return(true)
    allow(described_class).to receive(:portal_url).and_return('https://example.com/tool-checkouts?mode=self-service')
    SlackUser.create!(member: member, slack_id: 'UCHECKOUT', slack_email: member.email)
  end

  def checkout(days, **attributes)
    create(:tool_checkout, member: member, expires_on: today + days, defer_group_callbacks: true, **attributes)
  end

  it 'groups warning stages together and newly expired checkouts separately, once per channel' do
    [14, 3, -1, -4].each { |days| checkout(days) }
    described_class.run!
    expect(CheckoutMailer).to have_received(:expiration_notice).with(member.id.to_s, an_instance_of(Array), 'upcoming').once
    expect(CheckoutMailer).to have_received(:expiration_notice).with(member.id.to_s, an_instance_of(Array), 'expired').once
    expect(Service::SlackConnector).to have_received(:send_slack_message).twice
    described_class.run!
    expect(Service::SlackConnector).to have_received(:send_slack_message).twice
    expect(CheckoutMailer).to have_received(:expiration_notice).twice
  end

  it 'sends only the most urgent stage after a late run' do
    row = checkout(2)
    described_class.run!
    expect(row.reload.expiration_notice_state).to eq('email' => 2, 'slack' => 2)
    row.set(expires_on: today - 1)
    described_class.run!
    expect(row.reload.expiration_notice_state).to eq('email' => 3, 'slack' => 3)
  end

  it 'queues each affected shop once per scan until a rebuild completes' do
    shop = create(:shop)
    other_shop = create(:shop)
    checkout(-1, tool: create(:tool, shop: shop))
    checkout(-4, tool: create(:tool, shop: shop))
    checkout(-2, tool: create(:tool, shop: other_shop))
    allow(ToolCheckoutSlackCanvasSyncJob).to receive(:perform_later) do
      expect(CheckoutMailer).to have_received(:expiration_notice)
      true
    end

    2.times { described_class.run! }

    expect(ToolCheckoutSlackCanvasSyncJob).to have_received(:perform_later).with(shop.id.to_s).twice
    expect(ToolCheckoutSlackCanvasSyncJob).to have_received(:perform_later).with(other_shop.id.to_s).twice
    expect(ToolCheckoutSlackCanvasSyncJob).to have_received(:perform_later).exactly(4).times
  end

  it 'skips completed rebuilds but retries legacy enqueue-only markers' do
    checkout(-1, expiration_notice_state: { 'canvas_completed' => 3 })
    pending = checkout(-1, expiration_notice_state: { 'canvas' => 3 })

    described_class.run!

    expect(ToolCheckoutSlackCanvasSyncJob).to have_received(:perform_later).with(pending.tool.shop_id.to_s).once
    expect(ToolCheckoutSlackCanvasSyncJob).to have_received(:perform_later).once
  end

  it 'does not rebuild for warnings, expiration today, undated, revoked or superseded checkouts' do
    [14, 3, 0].each { |days| checkout(days) }
    create(:tool_checkout, member: member, defer_group_callbacks: true)
    checkout(-1, revoked_at: Time.current)
    checkout(-1, superseded_by_id: BSON::ObjectId.new)

    described_class.run!

    expect(ToolCheckoutSlackCanvasSyncJob).not_to have_received(:perform_later)
  end

  it 'rebuilds for expired checkouts even when member notices are suppressed' do
    # Establish eligibility before creating the checkout: changing a member's
    # status also enqueues roster updates for their existing checkouts.
    member.update!(status: 'inactive')
    row = checkout(-1)

    described_class.run!

    expect(CheckoutMailer).not_to have_received(:expiration_notice)
    expect(ToolCheckoutSlackCanvasSyncJob).to have_received(:perform_later).with(row.tool.shop_id.to_s).once
  end

  it 'does not mark a new expiration revision when the date changes during enqueue' do
    row = checkout(-1)
    allow(ToolCheckoutSlackCanvasSyncJob).to receive(:perform_later) do
      row.set(expires_on: today + 1, expiration_revision: 1, expiration_notice_state: {})
      true
    end

    described_class.run!

    expect(row.reload.expiration_notice_state).to eq({})
  end

  it 'still rebuilds when a delivery fails and retries a failed enqueue' do
    row = checkout(-1)
    allow(delivery).to receive(:deliver_now).and_raise('Email unavailable')
    allow(ToolCheckoutSlackCanvasSyncJob).to receive(:perform_later).and_return(false)
    expect { described_class.run! }.to raise_error(/failed/)
    expect(row.reload.expiration_notice_state).not_to have_key('canvas_completed')

    allow(ToolCheckoutSlackCanvasSyncJob).to receive(:perform_later).and_return(true)
    expect { described_class.run! }.to raise_error(/failed/)
    expect(row.reload.expiration_notice_state).not_to have_key('canvas_completed')
  end

  it 'retries only failed channels and reports partial failure' do
    row = checkout(3)
    allow(Service::SlackConnector).to receive(:send_slack_message).and_raise('Slack unavailable')
    expect { described_class.run! }.to raise_error(/failed/)
    expect(row.reload.expiration_notice_state).to eq('email' => 2)
    allow(Service::SlackConnector).to receive(:send_slack_message).and_return(true)
    described_class.run!
    expect(CheckoutMailer).to have_received(:expiration_notice).once
    expect(row.reload.expiration_notice_state).to eq('email' => 2, 'slack' => 2)
  end

  it 'skips inactive members, revoked and superseded checkouts, and non-expiring checkouts' do
    checkout(3, revoked_at: Time.current)
    checkout(3, superseded_by_id: BSON::ObjectId.new)
    create(:tool_checkout, member: member)
    checkout(3)
    member.update!(status: 'inactive')
    described_class.run!
    expect(CheckoutMailer).not_to have_received(:expiration_notice)
  end

  it 'does not let missing Slack linkage block email' do
    member.slack_user.destroy!
    checkout(14)
    described_class.run!
    expect(CheckoutMailer).to have_received(:expiration_notice).once
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'notifies eligible pending members but suppresses suspended and revoked members' do
    tool = create(:tool, allow_pending: true)
    row = checkout(3, tool: tool)
    member.update!(status: 'pending')
    described_class.run!
    expect(CheckoutMailer).to have_received(:expiration_notice).once
    %w[revoked suspended].each do |status|
      member.set(status: status)
      row.set(expiration_notice_state: {}, expiration_revision: row.expiration_revision + 1)
      described_class.run!
    end
    expect(CheckoutMailer).to have_received(:expiration_notice).once
  end

  it 'rechecks dates after email before sending Slack' do
    row = checkout(3)
    allow(delivery).to receive(:deliver_now) { row.set(expires_on: today + 60, expiration_revision: 1, expiration_notice_state: {}) }
    described_class.run!
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    expect(row.reload.expiration_notice_state).to eq({})
  end

  it 'refuses concurrent deliveries for a member' do
    checkout(3)
    allow(REDIS).to receive(:set).and_return(false)
    expect { described_class.run! }.to raise_error(/failed/)
    expect(CheckoutMailer).not_to have_received(:expiration_notice)
  end
end
