require 'rails_helper'

RSpec.describe Service::MemberSoftDelete do
  let(:actor) { create(:member, :admin) }

  before do
    allow(Service::MemberAccess).to receive(:full_deprovision)
    allow(Service::AuditLogger).to receive(:log)
  end

  describe '.delete!' do
    it 'deprovisions access, sets merged_at, and logs the action' do
      member = create(:member, status: 'inactive')

      described_class.delete!(member, actor: actor)

      expect(Service::MemberAccess).to have_received(:full_deprovision).with(member)
      expect(member.reload.merged_at).to be_present
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(
          log_type: 'member',
          event_type: 'member_soft_deleted',
          resource_type: 'Member',
          resource_id: member.id,
          actor: actor,
          subject: member
        )
      )
    end

    it 'hides the member from default queries once deleted' do
      member = create(:member, status: 'inactive')

      described_class.delete!(member, actor: actor)

      expect(Member.where(id: member.id).first).to be_nil
      expect(Member.unscoped.where(id: member.id).first).to be_present
    end

    it 'raises and does not deprovision when the member is currently active and unexpired' do
      member = create(:member, status: 'activeMember', expirationTime: 1.day.from_now.to_i * 1000)

      expect { described_class.delete!(member, actor: actor) }.to raise_error(Service::MemberSoftDelete::ActiveMembershipError)

      expect(Service::MemberAccess).not_to have_received(:full_deprovision)
      expect(member.reload.merged_at).to be_nil
    end

    it 'raises when a live subscription exists regardless of status' do
      member = create(:member, status: 'inactive', subscription: true)

      expect { described_class.delete!(member, actor: actor) }.to raise_error(Service::MemberSoftDelete::ActiveMembershipError)
    end

    it 'raises when the member is already deleted' do
      member = create(:member, status: 'inactive')
      member.update_attribute(:merged_at, Time.current)

      expect { described_class.delete!(member, actor: actor) }.to raise_error(Service::MemberSoftDelete::AlreadyDeletedError)
    end
  end

  describe '.restore!' do
    it 'clears merged_at and logs the action' do
      member = create(:member, status: 'inactive')
      member.update_attribute(:merged_at, Time.current)

      described_class.restore!(member, actor: actor)

      expect(member.reload.merged_at).to be_nil
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(
          log_type: 'member',
          event_type: 'member_restored',
          resource_type: 'Member',
          resource_id: member.id,
          actor: actor,
          subject: member
        )
      )
    end

    it 'raises when the member is not deleted' do
      member = create(:member, status: 'inactive')

      expect { described_class.restore!(member, actor: actor) }.to raise_error(Service::MemberSoftDelete::NotDeletedError)
    end
  end
end
