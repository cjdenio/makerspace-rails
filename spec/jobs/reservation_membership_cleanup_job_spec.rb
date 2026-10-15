require "rails_helper"

RSpec.describe ReservationMembershipCleanupJob, type: :job do
  let(:member) { create(:member) }

  it "cancels current and future reservations when the member was revoked" do
    allow(ReservationLifecycleService).to receive(:cancel_current_and_future!)

    described_class.perform_now(member.id.to_s, "revoked")

    expect(ReservationLifecycleService).to have_received(:cancel_current_and_future!)
      .with(member, reason: "Membership was revoked")
  end

  it "cancels reservations beyond the membership when a subscription ended" do
    allow(ReservationLifecycleService).to receive(:cancel_beyond_membership!)

    described_class.perform_now(member.id.to_s, "subscription_ended")

    expect(ReservationLifecycleService).to have_received(:cancel_beyond_membership!)
      .with(member, reason: "Recurring membership was cancelled")
  end

  it "no-ops when the member no longer exists (Mongoid raise_not_found_error is false)" do
    allow(ReservationLifecycleService).to receive(:cancel_current_and_future!)
    missing_id = member.id.to_s
    member.destroy

    expect { described_class.perform_now(missing_id, "revoked") }.not_to raise_error
    expect(ReservationLifecycleService).not_to have_received(:cancel_current_and_future!)
  end
end
