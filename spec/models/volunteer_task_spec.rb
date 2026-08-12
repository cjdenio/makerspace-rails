require 'rails_helper'

describe VolunteerTask, type: :model do
  let(:admin)      { create(:member, :admin) }
  let(:member)     { create(:member, status: 'activeMember') }
  let(:inactive)   { create(:member, status: 'inactive') }
  let(:pending)    { create(:member, status: 'pending') }
  let(:revoked)    { create(:member, status: 'revoked') }
  let(:non_member) { create(:member, status: 'nonMember') }

  let(:valid_attrs) do
    {
      title:         'Reorganize woodshop',
      description:   'Sort and label all lumber bins',
      credit_value:  1.0,
      created_by_id: admin.id,
      status:        'available'
    }
  end

  before do
    allow(VolunteerTask).to receive(:max_credit_value).and_return(2.0)
    allow(EarnedMembership).to receive_message_chain(:where, :exists?).and_return(false)
    allow(SlackUser).to receive(:find_by).and_return(nil)
    allow(Service::SlackConnector).to receive(:enque_message)
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(SystemConfig).to receive(:get).and_call_original
    allow(SystemConfig).to receive(:set).and_call_original
  end

  # ── Validations ───────────────────────────────────────────────────────────

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(VolunteerTask.new(valid_attrs)).to be_valid
    end

    it 'requires title' do
      expect(VolunteerTask.new(valid_attrs.merge(title: nil))).not_to be_valid
    end

    it 'requires description' do
      expect(VolunteerTask.new(valid_attrs.merge(description: nil))).not_to be_valid
    end

    it 'accepts fractional credit values' do
      expect(VolunteerTask.new(valid_attrs.merge(credit_value: 0.5))).to be_valid
    end

    it 'rejects credit_value above max on create' do
      task = VolunteerTask.new(valid_attrs.merge(credit_value: 3.0))
      expect(task).not_to be_valid
      expect(task.errors[:credit_value]).to be_present
    end

    it 'allows credit_value at exactly the max' do
      expect(VolunteerTask.new(valid_attrs.merge(credit_value: 2.0))).to be_valid
    end

    it 'does not re-validate max credit on update' do
      task = VolunteerTask.create!(valid_attrs.merge(credit_value: 2.0))
      allow(VolunteerTask).to receive(:max_credit_value).and_return(1.0)
      task.title = 'Updated title'
      expect(task).to be_valid
    end

    it 'accepts all new multi-use statuses' do
      %w[reusable repeatable recurring].each do |s|
        days_val = s == 'recurring' ? 7 : nil
        expect(VolunteerTask.new(valid_attrs.merge(status: s, days: days_val))).to be_valid
      end
    end

    it 'requires days for recurring tasks' do
      task = VolunteerTask.new(valid_attrs.merge(status: 'recurring', days: nil))
      expect(task).not_to be_valid
      expect(task.errors[:days]).to be_present
    end

    it 'does not require days for non-recurring tasks' do
      expect(VolunteerTask.new(valid_attrs.merge(status: 'reusable', days: nil))).to be_valid
    end
  end

  # ── Standard #claim! ──────────────────────────────────────────────────────

  describe '#claim! (available)' do
    let(:task) { VolunteerTask.create!(valid_attrs) }

    it 'sets status to claimed and records the member' do
      task.claim!(member)
      expect(task.reload.status).to eq('claimed')
      expect(task.claimed_by_id).to eq(member.id)
      expect(task.claimed_at).not_to be_nil
    end

    it 'raises Forbidden if task is not available' do
      task.update!(status: 'claimed')
      expect { task.claim!(member) }.to raise_error(Error::Forbidden)
    end

    it 'raises Forbidden for inactive member' do
      expect { task.claim!(inactive) }.to raise_error(Error::Forbidden)
    end

    it 'raises Forbidden for a pending member' do
      expect(task.eligible_for?(pending)).to be(false)
      expect { task.claim!(pending) }.to raise_error(Error::Forbidden)
    end

    it 'raises Forbidden for revoked member' do
      expect { task.claim!(revoked) }.to raise_error(Error::Forbidden)
    end

    it 'raises Forbidden for nonMember' do
      expect { task.claim!(non_member) }.to raise_error(Error::Forbidden)
    end
  end

  # ── Reusable tasks ────────────────────────────────────────────────────────

  describe '#claim! (reusable)' do
    let(:task) { VolunteerTask.create!(valid_attrs.merge(status: 'reusable')) }

    it 'leaves the parent task untouched' do
      task.claim!(member)
      expect(task.reload.status).to eq('reusable')
      expect(task.reload.claimed_by_id).to be_nil
    end

    it 'creates a child task document with status claimed' do
      task  # force lazy let evaluation before counting
      expect { task.claim!(member) }.to change { VolunteerTask.count }.by(1)
      child = VolunteerTask.where(parent_task_id: task.id).last
      expect(child.status).to eq('claimed')
      expect(child.claimed_by_id).to eq(member.id)
      expect(child.parent_task_id).to eq(task.id)
    end

    it 'a member cannot claim a reusable task more than once' do
      task.claim!(member)
      # Mark the first child as claimed (default) — trying again should be blocked
      expect { task.claim!(member) }.to raise_error(Error::AlreadyClaimed)
    end

    it 'a different member can claim the same reusable task' do
      other = create(:member, status: 'activeMember')
      task.claim!(member)
      expect { task.claim!(other) }.to change { VolunteerTask.count }.by(1)
    end

    it 'allows re-claiming a reusable task after a prior child is denied' do
      task.claim!(member)
      child = VolunteerTask.where(parent_task_id: task.id).last
      child.update!(status: 'denied')
      # denied child should no longer block a new claim
      expect { task.claim!(member) }.to change { VolunteerTask.count }.by(1)
    end

    it 'raises Forbidden for non-active member' do
      expect { task.claim!(inactive) }.to raise_error(Error::Forbidden)
    end
  end

  # ── Repeatable tasks ──────────────────────────────────────────────────────

  describe '#claim! (repeatable)' do
    let(:task) { VolunteerTask.create!(valid_attrs.merge(status: 'repeatable')) }

    it 'a member can claim repeatable tasks multiple times' do
      task.claim!(member)
      first_child  = VolunteerTask.where(parent_task_id: task.id).last
      first_child.update!(status: 'completed')

      expect { task.claim!(member) }.to change { VolunteerTask.count }.by(1)
      children = VolunteerTask.where(parent_task_id: task.id).to_a
      expect(children.length).to eq(2)
      expect(children.all? { |c| c.claimed_by_id == member.id }).to be true
    end

    it 'leaves the parent status as repeatable after each claim' do
      task.claim!(member)
      expect(task.reload.status).to eq('repeatable')
    end

    it 'raises Forbidden for non-active member' do
      expect { task.claim!(inactive) }.to raise_error(Error::Forbidden)
    end
  end

  # ── Recurring tasks ───────────────────────────────────────────────────────

  describe '#claim! (recurring)' do
    let(:task) { VolunteerTask.create!(valid_attrs.merge(status: 'recurring', days: 7)) }

    it 'creates a child task on first claim' do
      task  # force lazy let evaluation before counting
      expect { task.claim!(member) }.to change { VolunteerTask.count }.by(1)
      child = VolunteerTask.where(parent_task_id: task.id).last
      expect(child.status).to eq('claimed')
    end

    it 'sets claimed_at and next_available on the parent' do
      task.claim!(member)
      task.reload
      expect(task.claimed_at).not_to be_nil
      expect(task.next_available).to eq(Date.today + 7.days)
    end

    it 'hides the parent while next_available is in the future' do
      task.claim!(member)
      expect(task.reload.currently_cooling_down?).to be true
      expect(VolunteerTask.claimable.to_a).not_to include(task)
    end

    it 'makes the parent claimable again once next_available has passed' do
      task.update!(next_available: Date.yesterday)
      expect(task.currently_cooling_down?).to be false
      expect(VolunteerTask.claimable.to_a).to include(task)
    end

    it 'raises CoolingDown when next_available is in the future' do
      task.claim!(member)
      other = create(:member, status: 'activeMember')
      expect { task.claim!(other) }.to raise_error(Error::CoolingDown)
    end

    it 'allows a new claim once the cooldown has expired' do
      task.update!(next_available: Date.yesterday)
      expect { task.claim!(member) }.to change { VolunteerTask.count }.by(1)
    end

    it 'raises Forbidden for non-active member' do
      expect { task.claim!(inactive) }.to raise_error(Error::Forbidden)
    end
  end

  # ── #mark_pending! ────────────────────────────────────────────────────────

  describe '#mark_pending!' do
    let(:task) { VolunteerTask.create!(valid_attrs.merge(status: 'claimed', claimed_by_id: member.id)) }

    it 'moves status to pending' do
      task.mark_pending!(member)
      expect(task.reload.status).to eq('pending')
    end

    it 'raises Forbidden if member is not the claimer' do
      other = create(:member)
      expect { task.mark_pending!(other) }.to raise_error(Error::Forbidden)
    end
  end

  # ── #complete! ────────────────────────────────────────────────────────────

  describe '#complete!' do
    let(:task) { VolunteerTask.create!(valid_attrs.merge(status: 'pending', claimed_by_id: member.id, credit_value: 1.5)) }

    it 'sets status to completed and issues a credit with correct value' do
      expect { task.complete!(admin) }.to change { VolunteerCredit.count }.by(1)
      expect(task.reload.status).to eq('completed')
      credit = VolunteerCredit.last
      expect(credit.member_id).to eq(member.id)
      expect(credit.credit_value).to eq(1.5)
      expect(credit.status).to eq('approved')
    end

    it 'raises Forbidden if verifier is the claimer' do
      task.update!(claimed_by_id: admin.id)
      expect { task.complete!(admin) }.to raise_error(Error::Forbidden)
    end

    it 'raises Forbidden if task is not pending' do
      task.update!(status: 'claimed')
      expect { task.complete!(admin) }.to raise_error(Error::Forbidden)
    end
  end

  # ── #release! ────────────────────────────────────────────────────────────

  describe '#release!' do
    let(:task) { VolunteerTask.create!(valid_attrs.merge(status: 'claimed', claimed_by_id: member.id)) }

    it 'returns a standard task to available and clears claimant' do
      task.release!(admin, 'No response from member')
      expect(task.reload.status).to eq('available')
      expect(task.claimed_by_id).to be_nil
      expect(task.rejection_reason).to eq('No response from member')
    end

    it 'raises Forbidden if task is not claimed' do
      task.update!(status: 'available', claimed_by_id: nil)
      expect { task.release!(admin, 'reason') }.to raise_error(Error::Forbidden)
    end

    it 'raises Forbidden if admin is the claimer' do
      task.update!(claimed_by_id: admin.id)
      expect { task.release!(admin, 'reason') }.to raise_error(Error::Forbidden)
    end

    it 'attempts to DM the former claimant when Slack linked' do
      slack_user = double('SlackUser', slack_id: 'U456')
      allow(SlackUser).to receive(:find_by).with(member_id: member.id).and_return(slack_user)
      expect(Service::SlackConnector).to receive(:send_slack_message).with(anything, 'U456')
      task.release!(admin, 'No response from member')
    end

    context 'when releasing a child task (reusable/repeatable/recurring)' do
      let(:parent) { VolunteerTask.create!(valid_attrs.merge(status: 'reusable')) }
      let(:child) do
        VolunteerTask.create!(
          valid_attrs.merge(
            status:         'claimed',
            claimed_by_id:  member.id,
            parent_task_id: parent.id
          )
        )
      end

      it 'sets child status to denied instead of resetting to available' do
        child.release!(admin, 'Work not done')
        expect(child.reload.status).to eq('denied')
      end

      it 'does not clear claimed_by_id on the child' do
        child.release!(admin, 'Work not done')
        expect(child.reload.claimed_by_id).to eq(member.id)
      end

      it 'leaves the parent task untouched' do
        child.release!(admin, 'Work not done')
        expect(parent.reload.status).to eq('reusable')
      end
    end
  end

  # ── #reject_pending! ──────────────────────────────────────────────────────

  describe '#reject_pending!' do
    let(:task) { VolunteerTask.create!(valid_attrs.merge(status: 'pending', claimed_by_id: member.id)) }

    it 'returns a standard task to available and clears claimant' do
      task.reject_pending!(admin, 'Work not completed to standard')
      expect(task.reload.status).to eq('available')
      expect(task.claimed_by_id).to be_nil
      expect(task.rejection_reason).to eq('Work not completed to standard')
    end

    it 'raises Forbidden if task is not pending' do
      task.update!(status: 'claimed')
      expect { task.reject_pending!(admin, 'reason') }.to raise_error(Error::Forbidden)
    end

    it 'raises Forbidden if admin is the claimer' do
      task.update!(claimed_by_id: admin.id)
      expect { task.reject_pending!(admin, 'reason') }.to raise_error(Error::Forbidden)
    end

    it 'attempts to DM the former claimant when Slack linked' do
      slack_user = double('SlackUser', slack_id: 'U456')
      allow(SlackUser).to receive(:find_by).with(member_id: member.id).and_return(slack_user)
      expect(Service::SlackConnector).to receive(:send_slack_message).with(anything, 'U456')
      task.reject_pending!(admin, 'Work not completed to standard')
    end

    context 'when rejecting a child task (reusable/repeatable/recurring)' do
      let(:parent) { VolunteerTask.create!(valid_attrs.merge(status: 'repeatable')) }
      let(:child) do
        VolunteerTask.create!(
          valid_attrs.merge(
            status:         'pending',
            claimed_by_id:  member.id,
            parent_task_id: parent.id
          )
        )
      end

      it 'sets child status to denied instead of resetting to available' do
        child.reject_pending!(admin, 'Not acceptable')
        expect(child.reload.status).to eq('denied')
      end

      it 'leaves the parent task untouched' do
        child.reject_pending!(admin, 'Not acceptable')
        expect(parent.reload.status).to eq('repeatable')
      end
    end
  end

  # ── #cancel! ─────────────────────────────────────────────────────────────

  describe '#cancel!' do
    let(:task) { VolunteerTask.create!(valid_attrs) }

    it 'sets status to cancelled' do
      task.cancel!
      expect(task.reload.status).to eq('cancelled')
    end
  end

  # ── Scopes ────────────────────────────────────────────────────────────────

  describe '.claimable scope' do
    it 'includes available tasks' do
      task = VolunteerTask.create!(valid_attrs.merge(status: 'available'))
      expect(VolunteerTask.claimable).to include(task)
    end

    it 'includes reusable tasks' do
      task = VolunteerTask.create!(valid_attrs.merge(status: 'reusable'))
      expect(VolunteerTask.claimable).to include(task)
    end

    it 'includes repeatable tasks' do
      task = VolunteerTask.create!(valid_attrs.merge(status: 'repeatable'))
      expect(VolunteerTask.claimable).to include(task)
    end

    it 'includes recurring tasks with no next_available set' do
      task = VolunteerTask.create!(valid_attrs.merge(status: 'recurring', days: 7, next_available: nil))
      expect(VolunteerTask.claimable).to include(task)
    end

    it 'includes recurring tasks whose next_available is today or earlier' do
      task = VolunteerTask.create!(valid_attrs.merge(status: 'recurring', days: 7, next_available: Date.today))
      expect(VolunteerTask.claimable).to include(task)
    end

    it 'excludes recurring tasks still in cooldown' do
      task = VolunteerTask.create!(valid_attrs.merge(status: 'recurring', days: 7, next_available: Date.tomorrow))
      expect(VolunteerTask.claimable).not_to include(task)
    end

    it 'excludes child tasks (has parent_task_id)' do
      parent = VolunteerTask.create!(valid_attrs.merge(status: 'reusable'))
      child  = VolunteerTask.create!(valid_attrs.merge(
        status:         'claimed',
        parent_task_id: parent.id,
        claimed_by_id:  member.id
      ))
      expect(VolunteerTask.claimable.where(parent_task_id: nil)).not_to include(child)
    end
  end
end
