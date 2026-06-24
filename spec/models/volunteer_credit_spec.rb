require 'rails_helper'

describe VolunteerCredit, type: :model do
  let(:admin)  { create(:member, :admin) }
  let(:member) { create(:member) }

  let(:valid_attrs) do
    {
      member_id:    member.id,
      issued_by_id: admin.id,
      description:  'Helped at cleanup day',
      credit_value: 1.0,
      status:       'approved'
    }
  end

  before do
    allow(EarnedMembership).to receive_message_chain(:where, :exists?).and_return(false)
    allow(SlackUser).to receive(:find_by).and_return(nil)
    allow(Service::SlackConnector).to receive(:enque_message)
    allow(Service::SlackConnector).to receive(:send_slack_message)
  end

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(VolunteerCredit.new(valid_attrs)).to be_valid
    end

    it 'requires member_id' do
      expect(VolunteerCredit.new(valid_attrs.merge(member_id: nil))).not_to be_valid
    end

    it 'requires description' do
      expect(VolunteerCredit.new(valid_attrs.merge(description: nil))).not_to be_valid
    end

    it 'requires credit_value > 0' do
      expect(VolunteerCredit.new(valid_attrs.merge(credit_value: 0))).not_to be_valid
    end

    it 'accepts fractional credit values' do
      expect(VolunteerCredit.new(valid_attrs.merge(credit_value: 0.5))).to be_valid
    end

    it 'rejects invalid status' do
      expect(VolunteerCredit.new(valid_attrs.merge(status: 'bogus'))).not_to be_valid
    end

    it 'does not allow approver to be same as member when status is approved' do
      credit = VolunteerCredit.new(valid_attrs.merge(member_id: admin.id, issued_by_id: admin.id, status: 'approved'))
      expect(credit).not_to be_valid
    end
  end

  describe '.year_count_for' do
    it 'sums approved credit values for the current year as a float' do
      VolunteerCredit.create!(valid_attrs.merge(credit_value: 1.0))
      VolunteerCredit.create!(valid_attrs.merge(credit_value: 0.5))
      VolunteerCredit.create!(valid_attrs.merge(credit_value: 1.0, status: 'pending', issued_by_id: nil))
      expect(VolunteerCredit.year_count_for(member.id)).to eq(1.5)
    end

    it 'does not count credits from previous years' do
      credit = VolunteerCredit.create!(valid_attrs)
      credit.set(created_at: 2.years.ago)
      expect(VolunteerCredit.year_count_for(member.id)).to eq(0.0)
    end
  end

  describe '#approve!' do
    let(:credit) { VolunteerCredit.create!(valid_attrs.merge(status: 'pending', issued_by_id: nil)) }

    it 'sets status to approved' do
      credit.approve!(admin)
      expect(credit.reload.status).to eq('approved')
    end

    it 'sets issued_by_id to the approver' do
      credit.approve!(admin)
      expect(credit.reload.issued_by_id).to eq(admin.id)
    end

    it 'raises Forbidden if approver is the member' do
      credit.update!(member_id: admin.id)
      expect { credit.approve!(admin) }.to raise_error(Error::Forbidden)
    end

    it 'attempts to DM the member via Slack when linked' do
      slack_user = double('SlackUser', slack_id: 'U123')
      allow(SlackUser).to receive(:find_by).with(member_id: member.id).and_return(slack_user)
      expect(Service::SlackConnector).to receive(:send_slack_message).with(anything, 'U123')
      credit.approve!(admin)
    end
  end

  describe '#reject!' do
    let(:credit) { VolunteerCredit.create!(valid_attrs.merge(status: 'pending', issued_by_id: nil)) }

    it 'sets status to rejected' do
      credit.reject!(admin)
      expect(credit.reload.status).to eq('rejected')
    end

    it 'raises Forbidden if rejector is the member' do
      credit.update!(member_id: admin.id)
      expect { credit.reject!(admin) }.to raise_error(Error::Forbidden)
    end
  end

  describe 'discount threshold' do
    before do
      allow(VolunteerCredit).to receive(:credits_per_discount).and_return(4.0)
      allow(VolunteerCredit).to receive(:max_discounts_per_year).and_return(2)
      allow(VolunteerCredit).to receive(:discount_id).and_return('monthly_membership_sso')
      allow_any_instance_of(VolunteerCredit).to receive(:apply_braintree_discount).and_return(nil)
      allow_any_instance_of(VolunteerCredit).to receive(:notify_no_subscription).and_return(nil)
      # notify_discount_applied NOT stubbed here — individual tests stub/expect it as needed
      # member needs a subscription_id for discount to apply
      member.update!(subscription_id: 'sub_test_123')
    end

    it 'triggers discount when credits reach threshold' do
      allow_any_instance_of(VolunteerCredit).to receive(:notify_discount_applied).and_return(nil)
      4.times do
        VolunteerCredit.create!(valid_attrs.merge(status: 'pending', issued_by_id: nil, credit_value: 1.0))
          .tap { |c| c.approve!(admin) }
      end
      expect(VolunteerCredit.where(member_id: member.id, discount_applied: true).count).to eq(4)
    end

    it 'triggers discount with fractional credits summing to threshold' do
      allow_any_instance_of(VolunteerCredit).to receive(:notify_discount_applied).and_return(nil)
      2.times do
        VolunteerCredit.create!(valid_attrs.merge(status: 'pending', issued_by_id: nil, credit_value: 2.0))
          .tap { |c| c.approve!(admin) }
      end
      applied_sum = VolunteerCredit.where(member_id: member.id, discount_applied: true).sum(:credit_value)
      expect(applied_sum).to eq(4.0)
    end

    it 'does not trigger discount when sum falls short' do
      allow_any_instance_of(VolunteerCredit).to receive(:notify_discount_applied).and_return(nil)
      3.times do
        VolunteerCredit.create!(valid_attrs.merge(status: 'pending', issued_by_id: nil, credit_value: 1.0))
          .tap { |c| c.approve!(admin) }
      end
      expect(VolunteerCredit.where(member_id: member.id, discount_applied: true).count).to eq(0)
    end

    it 'does not apply discount for earned membership members' do
      allow_any_instance_of(VolunteerCredit).to receive(:notify_discount_applied).and_return(nil)
      allow(EarnedMembership).to receive_message_chain(:where, :exists?).and_return(true)
      4.times do
        VolunteerCredit.create!(valid_attrs.merge(status: 'pending', issued_by_id: nil, credit_value: 1.0))
          .tap { |c| c.approve!(admin) }
      end
      expect(VolunteerCredit.where(member_id: member.id, discount_applied: true).count).to eq(0)
    end

    it 'stops applying discounts after max_discounts_per_year' do
      allow_any_instance_of(VolunteerCredit).to receive(:notify_discount_applied).and_return(nil)
      8.times do
        VolunteerCredit.create!(valid_attrs.merge(status: 'pending', issued_by_id: nil, credit_value: 1.0))
          .tap { |c| c.approve!(admin) }
      end
      VolunteerCredit.create!(valid_attrs.merge(status: 'pending', issued_by_id: nil, credit_value: 1.0))
        .tap { |c| c.approve!(admin) }
      applied_sum = VolunteerCredit.where(member_id: member.id, discount_applied: true).sum(:credit_value)
      expect(applied_sum).to eq(8.0)
    end

    it 'notifies treasurer channel when discount is triggered' do
      notified = 0
      allow_any_instance_of(VolunteerCredit).to receive(:notify_discount_applied) { notified += 1 }
      allow_any_instance_of(VolunteerCredit).to receive(:apply_braintree_discount) do |instance|
        instance.send(:notify_discount_applied, member, { amount: '10.00' })
      end
      attrs = { member_id: member.id, issued_by_id: admin.id, description: 'test', credit_value: 1.0, status: 'pending' }
      4.times do
        VolunteerCredit.create!(attrs)
          .tap { |c| c.approve!(admin) }
      end
      expect(notified).to be > 0
    end
  end
end
