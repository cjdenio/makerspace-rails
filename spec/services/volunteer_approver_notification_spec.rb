require 'rails_helper'

RSpec.describe VolunteerApproverNotification do
  let(:now) { Time.zone.local(2026, 10, 4, 12) }
  let(:shop) { create(:shop) }
  let(:admin) { create(:member, :admin) }
  let(:claimant) { create(:member) }

  around do |example|
    Time.use_zone('America/New_York') { travel_to(now) { example.run } }
  end

  before do
    # Race examples override only reviewer enumeration; fixture initialization
    # and reload callbacks still need Member's default-scope queries.
    allow(Member).to receive(:where).and_call_original
    allow(Service::MemberProvisioning).to receive(:invite_slack)
    allow(VolunteerSlackCanvasSyncJob).to receive(:perform_later)
    allow(ShortUrl).to receive(:base_url).and_return('https://portal.example.org')
    allow(Service::SlackConnector).to receive(:message_destination_mode).and_return('production')
    allow(Service::SlackConnector).to receive(:send_slack_message) do |_text, slack_id|
      { 'ts' => "receipt-#{slack_id}", 'channel' => "D-#{slack_id}" }
    end
    allow(Service::ErrorReporter).to receive(:notify)
    allow(SystemConfig).to receive(:record_run)
  end

  def reviewer(slack_id: nil, shop_ids: [shop.id.to_s], invalidated: false, **attributes)
    manager = create(:member, **{
      role: 'resource_manager', resource_manager_shop_ids: shop_ids
    }.merge(attributes))
    if slack_id
      SlackUser.create!(member: manager, slack_id: slack_id, slack_email: manager.email,
        invalidated_at: invalidated ? now : nil)
    end
    manager
  end

  def task(**attributes)
    VolunteerTask.create!({
      title: 'Sort lumber', description: 'Label the bins', shop_id: shop.id,
      created_by_id: admin.id, status: 'pending', claimed_by_id: claimant.id,
      claimed_at: now - 1.day, completed_at: now - 1.hour
    }.merge(attributes))
  end

  def event(**attributes)
    VolunteerEvent.create!({
      title: 'Shop cleanup', shop_id: shop.id, created_by_id: admin.id,
      event_date: now.to_date, attendee_ids: [claimant.id, admin.id]
    }.merge(attributes))
  end

  def task_receipts(record)
    record.reload
    key = "submission_#{(record.completed_at.to_f * 1000).round}"
    record.approver_notifications.fetch(key)
  end

  def receipts_for(record)
    record.is_a?(VolunteerTask) ? task_receipts(record) : record.reload.approver_notifications.fetch(event_key(record.event_date))
  end

  def event_key(date)
    date ? "event_#{date.strftime('%Y%m%d')}" : 'event_undated'
  end

  def enumerate_reviewers_once(*managers)
    enumeration_count = 0
    allow(Member).to receive(:where).with(role: 'resource_manager', resource_manager_shop_ids: shop.id.to_s)
      .and_wrap_original do |original, *arguments|
        enumeration_count += 1
        enumeration_count == 1 ? managers : original.call(*arguments)
      end
  end

  def change_before_delivery(record, &change)
    reload_count = 0
    allow(record).to receive(:reload).and_wrap_original do |original, *arguments|
      reload_count += 1
      change.call if reload_count == 2
      original.call(*arguments)
    end
  end

  it 'persists one DM receipt only for an actual resource manager assigned to the task shop' do
    assigned = reviewer(slack_id: 'UASSIGNED')
    reviewer(slack_id: 'UOTHER', shop_ids: [create(:shop).id.to_s])
    %w[member admin board_member].each { |role| reviewer(slack_id: "U#{role}", role: role) }
    claim = task

    2.times { described_class.notify!(claim, now: now) }

    expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(
      a_string_including(claimant.fullname, claim.display_number,
        "https://portal.example.org/volunteer?task=#{claim.id}"), 'UASSIGNED'
    )
    receipts = task_receipts(claim)
    expect(receipts.keys).to eq([assigned.id.to_s])
    expect(receipts.fetch(assigned.id.to_s)).to include(
      'state' => 'sent', 'ts' => 'receipt-UASSIGNED', 'channel' => 'D-UASSIGNED',
      'sent_at' => now, 'destination_mode' => 'production'
    )
  end

  it 'excludes missing, blank and invalidated Slack links, suppressed managers and the claimant' do
    assigned = reviewer(slack_id: 'UELIGIBLE')
    reviewer
    reviewer(slack_id: '')
    reviewer(slack_id: 'UINVALIDATED', invalidated: true)
    %w[revoked suspended].each { |status| reviewer(slack_id: "U#{status}", status: status) }
    self_reviewer = reviewer(slack_id: 'USELF')
    claim = task(claimed_by_id: self_reviewer.id)

    described_class.notify!(claim, now: now)

    expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(anything, 'UELIGIBLE')
    expect(task_receipts(claim).keys).to eq([assigned.id.to_s])
  end

  %i[task event].each do |kind|
    {
      'shop assignment removal' => { 'resource_manager_shop_ids' => [] },
      'role removal' => { 'role' => 'member' },
      'suspension' => { 'status' => 'suspended' },
      'revocation' => { 'status' => 'revoked' }
    }.each do |change, attributes|
      it "retries the #{kind} manager after #{change} during delivery is reversed" do
        assigned = reviewer(slack_id: 'UCHANGED')
        assigned_id = assigned.id
        original_attributes = attributes.keys.to_h { |name| [name, assigned.read_attribute(name)] }
        remaining = reviewer(slack_id: 'UREMAINING')
        enumerate_reviewers_once(assigned, remaining)
        claim = kind == :task ? task : event(event_date: now.to_date - 1)
        change_before_delivery(claim) do
          Member.collection.find('_id' => assigned_id).update_one('$set' => attributes)
        end

        2.times { described_class.notify!(claim, now: now) }

        expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'UCHANGED')
        expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(anything, 'UREMAINING')
        receipts = receipts_for(claim)
        expect(receipts.fetch(assigned_id.to_s)['state']).to eq('failed')
        expect(receipts.fetch(remaining.id.to_s)['state']).to eq('sent')

        Member.collection.find('_id' => assigned_id).update_one('$set' => original_attributes)
        2.times { described_class.notify!(claim, now: now) }

        expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(
          a_string_including("https://portal.example.org/volunteer?#{kind}=#{claim.id}"), 'UCHANGED'
        )
        expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(anything, 'UREMAINING')
        expect(receipts_for(claim).fetch(assigned_id.to_s)).to include(
          'state' => 'sent', 'ts' => 'receipt-UCHANGED', 'channel' => 'D-UCHANGED'
        )
        expect(Service::ErrorReporter).not_to have_received(:notify)
      end
    end

    %w[moved cleared].each do |change|
      it "retries a #{kind} review when its shop is #{change} during delivery and then restored" do
        successful = reviewer(slack_id: 'USUCCESS')
        claim = kind == :task ? task : event(event_date: now.to_date - 1)
        described_class.notify!(claim, now: now)
        expect(receipts_for(claim).fetch(successful.id.to_s)['state']).to eq('sent')

        assigned = reviewer(slack_id: 'URESTORED')
        changed_shop_id = change == 'moved' ? create(:shop).id : nil
        change_before_delivery(claim) do
          claim.class.collection.find('_id' => claim.id).update_one('$set' => { 'shop_id' => changed_shop_id })
        end
        2.times { described_class.notify!(claim, now: now) }

        expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'URESTORED')
        expect(receipts_for(claim).fetch(assigned.id.to_s)['state']).to eq('failed')

        claim.class.collection.find('_id' => claim.id).update_one('$set' => { 'shop_id' => shop.id })
        2.times { described_class.notify!(claim, now: now) }

        expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(
          a_string_including("https://portal.example.org/volunteer?#{kind}=#{claim.id}"), 'URESTORED'
        )
        expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(anything, 'USUCCESS')
        expect(receipts_for(claim).fetch(assigned.id.to_s)).to include(
          'state' => 'sent', 'ts' => 'receipt-URESTORED', 'channel' => 'D-URESTORED'
        )
        expect(Service::ErrorReporter).not_to have_received(:notify)
      end
    end
  end

  it 'marks a deleted manager receipt obsolete and continues notifying remaining managers' do
    assigned = reviewer(slack_id: 'UDELETED')
    assigned_id = assigned.id
    remaining = reviewer(slack_id: 'UREMAINING')
    allow(Member).to receive(:where).with(role: 'resource_manager', resource_manager_shop_ids: shop.id.to_s)
      .and_return([assigned, remaining])
    claim = task
    reload_count = 0
    allow(claim).to receive(:reload).and_wrap_original do |original, *arguments|
      reload_count += 1
      Member.collection.find('_id' => assigned_id).delete_one if reload_count == 2
      original.call(*arguments)
    end

    described_class.notify!(claim, now: now)

    expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'UDELETED')
    expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(anything, 'UREMAINING')
    receipts = task_receipts(claim)
    expect(receipts.fetch(assigned_id.to_s)['state']).to eq('obsolete')
    expect(receipts.fetch(remaining.id.to_s)['state']).to eq('sent')
    expect(Service::ErrorReporter).not_to have_received(:notify)
  end

  %i[task event].each do |kind|
    context "when the #{kind} approver's Slack identity changes before delivery" do
      let(:claim) { kind == :task ? task : event(event_date: now.to_date - 1) }
      let(:assigned) { reviewer(slack_id: 'UOLD') }
      let(:slack_user) { SlackUser.find_by(member_id: assigned.id) }

      %w[invalidated detached reassigned].each do |change|
        it "skips the #{change} identity, retaining a retryable receipt and continuing to other managers" do
          old_identity = slack_user
          remaining = reviewer(slack_id: 'UREMAINING')
          replacement_owner = create(:member) if change == 'reassigned'
          allow(Member).to receive(:where).with(role: 'resource_manager', resource_manager_shop_ids: shop.id.to_s)
            .and_return([assigned, remaining])
          change_before_delivery(claim) do
            attributes = case change
            when 'invalidated' then { 'invalidated_at' => now }
            when 'detached' then { 'member_id' => nil }
            when 'reassigned' then { 'member_id' => replacement_owner.id }
            end
            SlackUser.collection.find('_id' => old_identity.id).update_one('$set' => attributes)
          end

          described_class.notify!(claim, now: now)

          expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'UOLD')
          expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(anything, 'UREMAINING')
          receipts = receipts_for(claim)
          expect(receipts.fetch(assigned.id.to_s)['state']).to eq('failed')
          expect(receipts.fetch(remaining.id.to_s)['state']).to eq('sent')
          expect(Service::ErrorReporter).not_to have_received(:notify)
        end
      end

      it 'sends only to the current linked identity when the original link is replaced during lease acquisition' do
        old_identity = slack_user
        change_before_delivery(claim) do
          SlackUser.collection.find('_id' => old_identity.id).update_one('$set' => { 'invalidated_at' => now })
          SlackUser.create!(member: assigned, slack_id: 'UCURRENT', slack_email: assigned.email)
        end

        2.times { described_class.notify!(claim, now: now) }

        expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'UOLD')
        expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(anything, 'UCURRENT')
        expect(receipts_for(claim).fetch(assigned.id.to_s)).to include(
          'state' => 'sent', 'ts' => 'receipt-UCURRENT', 'channel' => 'D-UCURRENT'
        )
        expect(Service::ErrorReporter).not_to have_received(:notify)
      end

      it 'delivers once after relinking an identity whose first attempt was skipped' do
        old_identity = slack_user
        change_before_delivery(claim) do
          SlackUser.collection.find('_id' => old_identity.id).update_one('$set' => { 'invalidated_at' => now })
        end
        described_class.notify!(claim, now: now)
        expect(receipts_for(claim).fetch(assigned.id.to_s)['state']).to eq('failed')

        SlackUser.create!(member: assigned, slack_id: 'URELINKED', slack_email: assigned.email)
        2.times { described_class.notify!(claim, now: now) }

        expect(Service::SlackConnector).not_to have_received(:send_slack_message).with(anything, 'UOLD')
        expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(anything, 'URELINKED')
        expect(receipts_for(claim).fetch(assigned.id.to_s)).to include(
          'state' => 'sent', 'ts' => 'receipt-URELINKED', 'channel' => 'D-URELINKED'
        )
        expect(Service::ErrorReporter).not_to have_received(:notify)
      end
    end
  end

  it 'notifies immediately on a child claim submission and the job does not resend its DM' do
    assigned = reviewer(slack_id: 'UCHILD')
    parent = task(status: 'repeatable', claimed_by_id: nil, claimed_at: nil, completed_at: nil)
    claim = parent.claim!(claimant)
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)

    claim.mark_pending!(claimant)
    VolunteerEventReminderJob.perform_now

    expect(claim.reload.status).to eq('pending')
    expect(claim.parent_task_id).to eq(parent.id)
    expect(task_receipts(claim).fetch(assigned.id.to_s)['state']).to eq('sent')
    expect(parent.reload.approver_notifications).to be_empty
    expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(
      a_string_including("https://portal.example.org/volunteer?task=#{claim.id}"), 'UCHILD'
    )
  end

  it 'sends one aggregate event review DM after its date, including across repeated job runs' do
    assigned = reviewer(slack_id: 'UEVENT')
    activity = event
    excluded = [
      event(title: 'Future', event_date: now.to_date + 3),
      event(title: 'Undated', event_date: nil),
      event(title: 'Closed', event_date: now.to_date - 1, status: 'closed'),
      event(title: 'Unscoped', event_date: now.to_date - 1, shop_id: nil)
    ]
    VolunteerEventReminderJob.perform_now
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    expect(activity.reload.approver_notifications).to be_empty

    travel 1.day
    2.times { VolunteerEventReminderJob.perform_now }

    expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(
      a_string_including(activity.display_number, '2 checked-in attendees',
        "https://portal.example.org/volunteer?event=#{activity.id}"), 'UEVENT'
    )
    expect(activity.reload.approver_notifications.fetch(event_key(activity.event_date)).fetch(assigned.id.to_s)).to include(
      'state' => 'sent', 'ts' => 'receipt-UEVENT', 'channel' => 'D-UEVENT'
    )
    excluded.each { |record| expect(record.reload.approver_notifications).to be_empty }
  end

  it 'sends fresh event review DMs after a supported date update and only after the new day passes' do
    assigned = reviewer(slack_id: 'URESCHEDULED')
    remaining = reviewer(slack_id: 'UREMAINING')
    activity = event(event_date: now.to_date - 1)
    original_date = activity.event_date
    described_class.notify!(activity, now: now)
    original_receipts = receipts_for(activity).deep_dup

    rescheduled_date = now.to_date + 3
    activity.update!(event_date: rescheduled_date)
    travel 2.days
    VolunteerEventReminderJob.perform_now
    travel 1.day
    VolunteerEventReminderJob.perform_now
    expect(Service::SlackConnector).to have_received(:send_slack_message).exactly(2).times

    travel 1.day
    2.times { VolunteerEventReminderJob.perform_now }

    [assigned, remaining].each do |manager|
      slack_id = manager == assigned ? 'URESCHEDULED' : 'UREMAINING'
      expect(Service::SlackConnector).to have_received(:send_slack_message).twice.with(
        a_string_including("https://portal.example.org/volunteer?event=#{activity.id}"), slack_id
      )
      expect(receipts_for(activity).fetch(manager.id.to_s)).to include('state' => 'sent', 'sent_at' => Time.current)
    end
    expect(activity.reload.approver_notifications.fetch(event_key(original_date))).to eq(original_receipts)
    expect(Service::ErrorReporter).not_to have_received(:notify)
  end

  it 'adopts successful legacy event receipts without resending an unchanged event review' do
    assigned = reviewer(slack_id: 'ULEGACY')
    activity = event(event_date: now.to_date - 1)
    original_receipt = { 'state' => 'sent', 'ts' => 'legacy.ts', 'channel' => 'DLEGACY', 'sent_at' => now }
    activity.set(approver_notifications: { 'event' => { assigned.id.to_s => original_receipt } })

    2.times { described_class.notify!(activity, now: now) }

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    expect(activity.reload.approver_notifications).not_to have_key('event')
    expect(receipts_for(activity).fetch(assigned.id.to_s)).to eq(original_receipt)
    expect(Service::ErrorReporter).not_to have_received(:notify)
  end

  it 'binds legacy event receipts to the old date when rescheduled before its first new-service scan' do
    assigned = reviewer(slack_id: 'ULEGACY')
    activity = event(event_date: now.to_date - 1)
    original_date = activity.event_date
    original_receipt = { 'state' => 'sent', 'ts' => 'legacy.ts', 'channel' => 'DLEGACY', 'sent_at' => now }
    activity.set(approver_notifications: { 'event' => { assigned.id.to_s => original_receipt } })

    activity.update!(event_date: now.to_date + 3)
    expect(activity.reload.approver_notifications).not_to have_key('event')
    expect(activity.approver_notifications.fetch(event_key(original_date)).fetch(assigned.id.to_s)).to eq(original_receipt)
    travel 3.days
    described_class.notify!(activity, now: Time.current)
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)

    travel 1.day
    2.times { described_class.notify!(activity, now: Time.current) }

    expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(
      a_string_including("https://portal.example.org/volunteer?event=#{activity.id}"), 'ULEGACY'
    )
    expect(receipts_for(activity).fetch(assigned.id.to_s)).to include('state' => 'sent', 'sent_at' => Time.current)
    expect(activity.approver_notifications.fetch(event_key(original_date)).fetch(assigned.id.to_s)).to eq(original_receipt)
    expect(Service::ErrorReporter).not_to have_received(:notify)
  end

  {
    'rescheduled to a future day' => false,
    'temporarily removed' => true
  }.each do |change, undated|
    it "keeps the event review retryable when its date is #{change} after lease acquisition" do
      assigned = reviewer(slack_id: 'URESCHEDULED')
      activity = event(event_date: now.to_date - 1)
      original_date = activity.event_date
      rescheduled_date = now.to_date + 3
      stored_date = Time.utc(rescheduled_date.year, rescheduled_date.month, rescheduled_date.day)
      change_before_delivery(activity) do
        VolunteerEvent.collection.find('_id' => activity.id).update_one(
          '$set' => { 'event_date' => undated ? nil : stored_date }
        )
      end

      described_class.notify!(activity, now: now)

      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
      expect(activity.reload.approver_notifications.fetch(event_key(original_date)).fetch(assigned.id.to_s)['state']).to eq('failed')

      if undated
        VolunteerEvent.collection.find('_id' => activity.id).update_one('$set' => { 'event_date' => stored_date })
      end
      travel 2.days
      described_class.notify!(activity, now: Time.current)
      travel 1.day
      described_class.notify!(activity, now: Time.current)

      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
      expect(activity.reload.approver_notifications.fetch(event_key(original_date)).fetch(assigned.id.to_s)['state']).to eq('failed')

      travel 1.day
      2.times { described_class.notify!(activity, now: Time.current) }

      expect(Service::SlackConnector).to have_received(:send_slack_message).once.with(
        a_string_including("https://portal.example.org/volunteer?event=#{activity.id}"), 'URESCHEDULED'
      )
      expect(activity.reload.approver_notifications.fetch(event_key(rescheduled_date)).fetch(assigned.id.to_s)).to include(
        'state' => 'sent', 'ts' => 'receipt-URESCHEDULED', 'channel' => 'D-URESCHEDULED', 'sent_at' => Time.current
      )
      expect(Service::ErrorReporter).not_to have_received(:notify)
    end
  end

  it 'retries only the manager whose DM failed and preserves another manager\'s successful receipt' do
    successful = reviewer(slack_id: 'USUCCESS')
    failed = reviewer(slack_id: 'UFAILURE')
    claim = task
    allow(Service::SlackConnector).to receive(:send_slack_message).with(anything, 'UFAILURE')
      .and_raise(StandardError, 'Slack unavailable')

    expect { described_class.notify!(claim, now: now) }.not_to raise_error
    receipts = task_receipts(claim)
    expect(receipts.fetch(successful.id.to_s)['state']).to eq('sent')
    expect(receipts.fetch(failed.id.to_s)['state']).to eq('failed')

    allow(Service::SlackConnector).to receive(:send_slack_message).with(anything, 'UFAILURE')
      .and_return({ 'ts' => 'retry.ts', 'channel' => 'D-UFAILURE' })
    described_class.notify!(claim, now: now)

    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'USUCCESS').once
    expect(Service::SlackConnector).to have_received(:send_slack_message).with(anything, 'UFAILURE').twice
    expect(task_receipts(claim).fetch(failed.id.to_s)).to include('state' => 'sent', 'ts' => 'retry.ts')
    expect(Service::ErrorReporter).to have_received(:notify).with(an_instance_of(StandardError))
  end

  it 'does not notify for unscoped tasks or work that is not submitted for approval' do
    reviewer(slack_id: 'URM')
    records = [
      task(shop_id: nil), task(status: 'claimed', completed_at: nil),
      task(status: 'completed'), task(completed_at: nil)
    ]

    records.each { |record| described_class.notify!(record, now: now) }

    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    records.each { |record| expect(record.reload.approver_notifications).to be_empty }
  end
end
