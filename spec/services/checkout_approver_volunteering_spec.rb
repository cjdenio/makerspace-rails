require "rails_helper"

RSpec.describe CheckoutApproverVolunteering do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:member) { create(:member, :current, startDate: Time.zone.local(2024, 2, 3)) }
  let!(:checkout) { create(:tool_checkout, member: member, tool: tool, checked_out_at: Time.zone.local(2026, 4, 5)) }

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end

  it "saves the request note and sends RMs the note, checkout date, and join date" do
    manager = create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
    SlackUser.create!(member: manager, slack_id: "URM", slack_email: manager.email)
    allow(Service::SlackConnector).to receive(:send_slack_message)

    request = described_class.create!(member: member, tool: tool, note: "Happy to help")

    expect(request).to be_open
    expect(request.note).to eq("Happy to help")
    expect(CheckoutNotificationJob).to have_been_enqueued.with("approver_volunteer", request.id.to_s)
    described_class.deliver_request_notifications(request)
    expect(Service::SlackConnector).to have_received(:send_slack_message)
      .with(include(member.fullname, tool.name, "Happy to help", "2026-04-05", "2024-02-03"), "URM")
  end

  it "notifies and authorizes tagged admin and board shop contacts" do
    contacts = %w[admin board_member].map do |role|
      contact = create(:member, :current, role: role, resource_manager_shop_ids: [shop.id.to_s])
      SlackUser.create!(member: contact, slack_id: "U#{role.upcase}", slack_email: contact.email)
      contact
    end
    ordinary = create(:member, :current, resource_manager_shop_ids: [shop.id.to_s])
    SlackUser.create!(member: ordinary, slack_id: "UORDINARY", slack_email: ordinary.email)
    allow(Service::SlackConnector).to receive(:send_slack_message)

    request = described_class.create!(member: member, tool: tool)

    described_class.deliver_request_notifications(request)

    contacts.each do |contact|
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(include(tool.name), "U#{contact.role.upcase}")
      expect(described_class.reviewer?(contact, shop.id)).to be(true)
    end
    expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, "UORDINARY")
    described_class.approve!(request: request, actor: contacts.first)
    expect(request.reload.status).to eq("approved")
  end

  it "allows the containing shop RM to approve with a note and DMs the requestor" do
    manager = create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
    SlackUser.create!(member: member, slack_id: "UVOLUNTEER", slack_email: member.email)
    request = CheckoutApproverRequest.create!(member: member, tool: tool)
    allow(Service::SlackConnector).to receive(:send_slack_message)

    described_class.approve!(request: request, actor: manager, note: "Welcome aboard")

    expect(CheckoutApprover.find_by(member_id: member.id)).to be_can_approve_tool(tool)
    expect(request.reload).to have_attributes(status: "approved", decision_note: "Welcome aboard")
    expect(CheckoutNotificationJob).to have_been_enqueued.with("approver_volunteer_decision", request.id.to_s)
    described_class.deliver_decision_notification(request)
    expect(Service::SlackConnector).to have_received(:send_slack_message)
      .with(include("approved", "Welcome aboard"), "UVOLUNTEER")
  end

  it "allows the containing shop RM to decline with a note and DMs the requestor" do
    manager = create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
    SlackUser.create!(member: member, slack_id: "UVOLUNTEER", slack_email: member.email)
    request = CheckoutApproverRequest.create!(member: member, tool: tool)
    allow(Service::SlackConnector).to receive(:send_slack_message)

    described_class.decline!(request: request, actor: manager, note: "More experience needed")

    expect(request.reload).to have_attributes(status: "declined", decision_note: "More experience needed")
    expect(CheckoutApprover.where(member_id: member.id)).to be_empty
    expect(CheckoutNotificationJob).to have_been_enqueued.with("approver_volunteer_decision", request.id.to_s)
    described_class.deliver_decision_notification(request)
    expect(Service::SlackConnector).to have_received(:send_slack_message)
      .with(include("declined", "More experience needed"), "UVOLUNTEER")
  end

  it "does not DM a volunteer whose direct notifications became suppressed" do
    SlackUser.create!(member: member, slack_id: "UVOLUNTEER", slack_email: member.email)
    request = CheckoutApproverRequest.create!(member: member, tool: tool, status: "approved")
    member.update!(status: "suspended")
    allow(Service::SlackConnector).to receive(:send_slack_message)

    described_class.deliver_decision_notification(request)

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it "serializes creation with checkout revocation" do
    request = described_class.create!(member: member, tool: tool)

    expect(request).to be_open
    expect(REDIS).to have_received(:set).with(
      "checkout_request_lock/#{member.id}/#{tool.id}", anything, nx: true, ex: 30)
  end

  it "rechecks volunteer membership before granting access" do
    manager = create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
    request = CheckoutApproverRequest.create!(member: member, tool: tool)
    member.update!(status: "suspended")

    expect { described_class.approve!(request: request, actor: manager) }
      .to raise_error(Error::UnprocessableEntity, /membership is no longer eligible/)
    expect(CheckoutApprover.where(member_id: member.id)).to be_empty
  end

  it "serializes approver assignments per member across different tools" do
    manager = create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
    other_tool = create(:tool, shop: shop)
    create(:tool_checkout, member: member, tool: other_tool)
    requests = [tool, other_tool].map { |row| CheckoutApproverRequest.create!(member: member, tool: row) }

    requests.each { |request| described_class.approve!(request: request, actor: manager) }

    expect(CheckoutApprover.find_by(member_id: member.id).tool_ids.map(&:to_s)).to contain_exactly(tool.id.to_s, other_tool.id.to_s)
    expect(REDIS).to have_received(:set).with("checkout_approver_lock/#{member.id}", anything, nx: true, ex: 30).twice
  end

  it "rechecks request state under the decision lock before granting access" do
    manager = create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
    request = CheckoutApproverRequest.create!(member: member, tool: tool)
    allow(request).to receive(:reload) { request.status = "declined"; request }

    expect { described_class.approve!(request: request, actor: manager) }
      .to raise_error(Error::UnprocessableEntity, /no longer open/)
    expect(CheckoutApprover.where(member_id: member.id)).to be_empty
  end

  it "removes a newly granted assignment when recording approval fails" do
    manager = create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
    request = CheckoutApproverRequest.create!(member: member, tool: tool)
    allow(request).to receive(:update!).and_raise(Mongo::Error::SocketError, "write failed")

    expect { described_class.approve!(request: request, actor: manager) }
      .to raise_error(Mongo::Error::SocketError, "write failed")

    expect(CheckoutApprover.where(member_id: member.id)).to be_empty
    expect(request.reload).to be_open
  end

  it "revokes tool approver access and open requests when checkout is revoked" do
    CheckoutApprover.create!(member: member, tool_ids: [tool.id.to_s])
    request = CheckoutApproverRequest.create!(member: member, tool: tool)

    checkout.update!(revoked_at: Time.current)

    expect(CheckoutApprover.where(member_id: member.id)).to be_empty
    expect(request.reload.status).to eq("revoked")
  end
end
