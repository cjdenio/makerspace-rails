require "rails_helper"

RSpec.describe "Checkout request annotations" do
  let(:shop) { create(:shop, requestor_annotation: "Shop instructions") }
  let(:tool) { create(:tool, shop: shop, announce: false) }
  let(:member) { create(:member, :current) }

  before do
    SlackUser.create!(member: member, slack_id: "UANNOTATION")
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    allow(Service::SlackConnector).to receive(:send_slack_message)
  end

  def submit(**options)
    CheckoutRequestCreation.create!(member_id: member.id, tool_id: tool.id, shop_id: shop.id, **options)
  end

  it "DMs the shop fallback even when channel announcements are disabled" do
    submit
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(include("Shop instructions"), "UANNOTATION")
  end

  it "prefers the tool annotation and escapes Slack mentions" do
    tool.update!(requestor_annotation: "Ask <@U123> & wait")
    submit
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(
      include("Ask &lt;@U123&gt; &amp; wait").and(satisfy { |message| !message.include?("Shop instructions") }), "UANNOTATION")
  end

  it "normalizes blank annotations and omits the section when neither is set" do
    tool.update!(requestor_annotation: " \n ")
    shop.update!(requestor_annotation: nil)
    expect(tool.reload.requestor_annotation).to be_nil
    submit
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(satisfy { |message| !message.include?("Annotation for requestors") }, "UANNOTATION")
  end

  it "delivers the annotation through deferred modal notifications" do
    request = submit(defer_notifications: true)
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    CheckoutNotificationJob.perform_now("request", request.id.to_s)
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(include("Shop instructions"), "UANNOTATION")
  end

  it "serializes current annotations for existing requests" do
    request = submit
    tool.update!(requestor_annotation: "Updated tool instructions")
    expect(ToolCheckoutRequestSerializer.new(request.reload).serializable_hash[:requestor_annotation]).to eq("Updated tool instructions")
    tool.update!(requestor_annotation: nil)
    shop.update!(requestor_annotation: "Updated shop instructions")
    expect(ToolCheckoutRequestSerializer.new(request.reload).serializable_hash[:requestor_annotation]).to eq("Updated shop instructions")
  end

  it "does not notify on a rejected duplicate request" do
    submit
    expect { submit }.to raise_error(Error::UnprocessableEntity)
    expect(Service::SlackConnector).to have_received(:send_slack_message).once
  end
  it 'serializes the group shop annotation, including changes and removal' do
    group = ToolGroup.create!(shop: shop, name: 'Kit', included_tool_ids: [tool.id.to_s])
    request = ToolCheckoutRequest.create!(member: member, tool_group: group)
    expect(ToolCheckoutRequestSerializer.new(request).serializable_hash[:requestor_annotation]).to eq('Shop instructions')
    shop.update!(requestor_annotation: 'New group instructions')
    expect(ToolCheckoutRequestSerializer.new(request.reload).serializable_hash[:requestor_annotation]).to eq('New group instructions')
    shop.update!(requestor_annotation: nil)
    expect(ToolCheckoutRequestSerializer.new(request.reload).serializable_hash[:requestor_annotation]).to be_nil
  end

end
