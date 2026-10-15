require "rails_helper"

RSpec.describe CheckoutApproverCredit do
  let(:shop) { create(:shop) }
  let(:tool) { create(:tool, shop: shop) }
  let(:member) { create(:member, :current) }
  let(:approver) { create(:member, :current) }

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end

  it "silently awards 0.25 approved credits to an additional approver" do
    CheckoutApprover.create!(member: approver, tool_ids: [tool.id.to_s])
    checkout = create(:tool_checkout, member: member, tool: tool, approved_by: approver)
    expect(Service::SlackConnector).not_to receive(:send_slack_message)

    credit = described_class.award!(checkout)

    expect(credit).to have_attributes(member_id: approver.id, issued_by_id: approver.id,
      credit_value: 0.25, status: "approved", tool_checkout_id: checkout.id)
    expect(checkout.reload.volunteer_credit_id).to eq(credit.id)
  end


  it "recovers the checkout link without creating a duplicate credit" do
    CheckoutApprover.create!(member: approver, tool_ids: [tool.id.to_s])
    checkout = create(:tool_checkout, member: member, tool: tool, approved_by: approver)
    credit = described_class.award!(checkout)
    checkout.unset(:volunteer_credit_id)

    expect { described_class.award!(checkout.reload) }.not_to change(VolunteerCredit, :count)
    expect(checkout.reload.volunteer_credit_id).to eq(credit.id)
  end

  it "does not award RMs, board members, admins, or unassigned members" do
    actors = [
      create(:member, :current),
      create(:member, :current, :admin),
      create(:member, :current, :board_member),
      create(:member, :current, :resource_manager, resource_manager_shop_ids: [shop.id.to_s])
    ]

    actors.each do |actor|
      checkout = create(:tool_checkout, member: member, tool: tool, approved_by: actor)
      expect(described_class.award!(checkout)).to be_nil
    end
    expect(VolunteerCredit.count).to eq(0)
  end

  it "silently offsets the credit when the checkout is revoked" do
    CheckoutApprover.create!(member: approver, tool_ids: [tool.id.to_s])
    checkout = create(:tool_checkout, member: member, tool: tool, approved_by: approver)
    credit = described_class.award!(checkout)
    expect(Service::SlackConnector).not_to receive(:send_slack_message)

    checkout.update!(revoked_at: Time.current)

    reversal = VolunteerCredit.find_by(reversal_of_id: credit.id)
    expect(reversal).to have_attributes(member_id: approver.id, credit_value: -0.25, status: "reversal")
    expect(credit.reload).to be_reversed
  end

  it "reuses the same reversal after the original-credit update fails" do
    CheckoutApprover.create!(member: approver, tool_ids: [tool.id.to_s])
    checkout = create(:tool_checkout, member: member, tool: tool, approved_by: approver)
    credit = described_class.award!(checkout)
    failed_once = false
    allow_any_instance_of(VolunteerCredit).to receive(:update!).and_wrap_original do |method, *args|
      if method.receiver.id == credit.id && !failed_once
        failed_once = true
        raise StandardError, "original update failed"
      end
      method.call(*args)
    end

    expect { described_class.reverse!(checkout) }.to raise_error(StandardError, "original update failed")
    expect { described_class.reverse!(checkout) }.not_to change {
      VolunteerCredit.where(reversal_of_id: credit.id).count
    }
    expect(VolunteerCredit.where(reversal_of_id: credit.id).count).to eq(1)
    expect(credit.reload).to be_reversed
  end

  it "preserves treasurer review for a reversed credit that funded a discount" do
    CheckoutApprover.create!(member: approver, tool_ids: [tool.id.to_s])
    checkout = create(:tool_checkout, member: member, tool: tool, approved_by: approver)
    credit = described_class.award!(checkout)
    credit.update!(discount_applied: true, discount_applied_at: Time.current)
    expect_any_instance_of(VolunteerCredit).to receive(:notify_braintree_review_needed)
      .with(approver, "Tool checkout revoked")

    described_class.reverse!(checkout)
  end

  it "attributes reversal and treasurer review to the persisted revoking actor" do
    revoker = create(:member, :current, :admin)
    CheckoutApprover.create!(member: approver, tool_ids: [tool.id.to_s])
    checkout = create(:tool_checkout, member: member, tool: tool, approved_by: approver,
      revoked_by_id: revoker.id)
    credit = described_class.award!(checkout)
    credit.update!(discount_applied: true, discount_applied_at: Time.current)
    expect_any_instance_of(VolunteerCredit).to receive(:notify_braintree_review_needed)
      .with(revoker, "Tool checkout revoked")

    described_class.reverse!(checkout)

    expect(credit.reload.reversed_by_id).to eq(revoker.id)
    expect(VolunteerCredit.find_by(reversal_of_id: credit.id).reversed_by_id).to eq(revoker.id)
  end
end
