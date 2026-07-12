require 'rails_helper'

RSpec.describe 'notification suppression', type: :mailer do
  describe MarketingMailer do
    it 'does not send marketing mail to members with silence_emails enabled' do
      member = create(:member, silence_emails: true)

      message = described_class.request_signup(member.id.to_s).deliver_now

      expect(message.perform_deliveries).to be(false)
    end
  end

  describe MemberMailer do
    it 'sends non-marketing mail to members with silence_emails enabled' do
      member = create(:member, silence_emails: true)

      message = described_class.request_document('member_contract', member.id.to_s).deliver_now

      expect(message.perform_deliveries).to be(true)
    end

    it 'does not send non-marketing mail to revoked members' do
      member = create(:member, status: 'revoked', silence_emails: true)

      message = described_class.request_document('member_contract', member.id.to_s).deliver_now

      expect(message.perform_deliveries).to be(false)
    end

    it 'does not send non-marketing mail to secondary household members' do
      primary = create(:member)
      secondary = create(:member, groupName: primary.id.to_s)

      message = described_class.request_document('member_contract', secondary.id.to_s).deliver_now

      expect(message.perform_deliveries).to be(false)
    end

    it 'sends household disbanded mail to secondary household members' do
      primary = create(:member)
      secondary = create(:member, groupName: primary.id.to_s)

      message = described_class.household_disbanded(secondary.id.to_s, primary.id.to_s, false).deliver_now

      expect(message.perform_deliveries).to be(true)
    end

    xit 'sends password changed security notices to secondary household members' do
      primary = create(:member)
      secondary = create(:member, groupName: primary.id.to_s)

      message = described_class.password_changed(secondary.id.to_s).deliver_now

      expect(message.perform_deliveries).to be(true)
    end

    xit 'sends admin password reset security notices to secondary household members' do
      primary = create(:member)
      secondary = create(:member, groupName: primary.id.to_s)

      message = described_class.admin_password_reset(secondary.email, 'reset-token').deliver_now

      expect(message.perform_deliveries).to be(true)
    end

    it 'sends signed document receipts to secondary household members' do
      primary = create(:member)
      secondary = create(:member, groupName: primary.id.to_s)

      message = described_class.send_document('member_contract', secondary.id.to_s, 'signed pdf content').deliver_now

      expect(message.perform_deliveries).to be(true)
    end
  end

  describe RentalMailer do
    it 'sends rental mail to secondary household members for their own rentals' do
      primary = create(:member)
      secondary = create(:member, groupName: primary.id.to_s)
      rental = create(:rental, member: secondary)

      message = described_class.rental_vacating(secondary.id.to_s, rental.id.to_s, 'the end of the current rental period').deliver_now

      expect(message.perform_deliveries).to be(true)
    end
  end

  describe BillingMailer do
    it 'sends billing mail to secondary household members for their own invoices' do
      primary = create(:member)
      secondary = create(:member, groupName: primary.id.to_s)
      rental = create(:rental, member: secondary)
      invoice = create(:invoice, member: secondary, resource_class: 'rental', resource_id: rental.id.to_s)

      message = described_class._new_invoice(secondary, invoice).deliver_now

      expect(message.perform_deliveries).to be(true)
    end
  end

end
