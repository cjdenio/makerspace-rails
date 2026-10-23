require 'rails_helper'

RSpec.describe Card, type: :model do
    let(:member) {create(:member, :current)}
    let(:card) {create(:card, member: member)}

    let(:expired_member) {create(:member, :expired)}
    let(:expired_card) {create(:card, member: expired_member)}

    let(:inacitve_member) {create(:member, :inactive)}
    let(:inactive_card) {create(:card, member: inacitve_member)}

  describe "Mongoid validations" do
    it { is_expected.to be_mongoid_document }
    it { is_expected.to be_stored_in(collection: 'cards') }

    it { is_expected.to have_field(:uid) }
    it { is_expected.to have_fields(:holder, :validity).of_type(String) }
    it { is_expected.to have_field(:expiry).of_type(Integer) }
  end

  describe "ActiveModel validations" do
    it { is_expected.to validate_presence_of(:uid) }
    it { is_expected.to validate_uniqueness_of(:uid) }

    it { is_expected.to belong_to(:member).as_inverse_of(:access_cards) }
  end

  it "has a valid factory" do
    expect(build(:card)).to be_valid
  end

  context "public methods" do
    it "Correctly identifies is_active" do
      expect(card.is_active?).to be_truthy
      expect(expired_card.is_active?).to be_truthy
      expect(inactive_card.is_active?).to be_falsy
    end
  end


  context "Callbacks" do
    describe "on create" do
      it "Sets holder, expiry and validty from member" do
        expect(card.holder).to eq(member.fullname)
        expect(card.expiry).to eq(member.expirationTime)
        expect(card.validity).to eq(member.status)
      end

      it "Updates rejection card where uid came from" do
        rejection_card = create(:rejection_card, { uid: "123" })
        expect(rejection_card.holder).to eq(nil)
        card = create(:card, uid: "123", member: member)
        rejection_card.reload
        expect(rejection_card.holder).to eq(member.fullname)
      end

      it "activates a pending member when their card is issued" do
        pending_member = create(:member, :current, status: 'pending')

        issued_card = create(:card, member: pending_member)

        expect(pending_member.reload.status).to eq('activeMember')
        expect(issued_card.reload.validity).to eq('activeMember')
      end

      it "activates a pending member without rerunning member validations after card insertion" do
        pending_member = create(:member, :current, status: 'pending')
        allow_any_instance_of(EmailDeliverabilityValidator).to receive(:validate_each) do |_validator, record, attribute, _value|
          record.errors.add(attribute, 'is no longer deliverable')
        end

        expect do
          create(:card, member: pending_member, uid: SecureRandom.hex(6))
        end.to change(Card, :count).by(1)

        expect(pending_member.reload.status).to eq('activeMember')
      end

      it "enqueues MemberProvisioningJob when a new card is created" do
        expect do
          create(:card, member: member, uid: SecureRandom.hex(6))
        end.to have_enqueued_job(MemberProvisioningJob).with(member.id.to_s)
      end
    end

    describe "on update" do
      it "Updates expiry and validity from member" do
        card.update({ member: expired_member})
        expect(card.expiry).to eq(expired_member.expirationTime)
        expect(card.validity).to eq(expired_member.status)
      end

      it "enqueues MemberProvisioningJob for a direct card update" do
        card # force lazy creation before the expect block, so its own
             # after_create enqueue isn't counted alongside the update's
        expect do
          card.update(card_location: 'lost')
        end.to have_enqueued_job(MemberProvisioningJob).with(member.id.to_s)
      end

      it "does not enqueue MemberProvisioningJob when skip_provisioning_enqueue is set (the Member#update_card cascade)" do
        card.skip_provisioning_enqueue = true
        expect do
          card.update(expiry: 1.month.from_now.to_i * 1000)
        end.not_to have_enqueued_job(MemberProvisioningJob)
      end
    end
  end
end
