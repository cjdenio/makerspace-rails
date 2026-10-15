require 'rails_helper'

RSpec.describe 'Member Home volunteer recommendations' do
  let(:member) { create(:member, :current) }
  subject(:home) { MemberHome.new(member) }

  before { allow(REDIS).to receive(:set).and_return(true) }

  def task(**attributes)
    VolunteerTask.create!({ title: 'Help in the shop', description: 'Organize supplies' }.merge(attributes))
  end

  def event(**attributes)
    VolunteerEvent.create!({ title: 'Help at the open house', event_date: Date.tomorrow }.merge(attributes))
  end

  def ids
    home.available_volunteer_opportunities.pluck(:id)
  end

  %w[pending inactive nonMember revoked suspended expired].each do |status|
    it "omits recommendations for #{status} members" do
      task
      event
      member.set(status: status)
      expect(home.available_volunteer_opportunities).to be_empty
    end
  end

  it 'samples up to five from the combined eligible pool, after filtering' do
    6.times { task(status: 'cancelled') }
    candidates = 6.times.map { |n| task(title: "Task #{n}") } + 6.times.map { |n| event(title: "Event #{n}") }
    first = home.available_volunteer_opportunities(random: Random.new(1))
    second = home.available_volunteer_opportunities(random: Random.new(2))
    expect(first.length).to eq(5)
    expect(first.pluck(:id).uniq.length).to eq(5)
    expect(first.pluck(:id) - candidates.map { |row| row.id.to_s }).to be_empty
    expect(first.pluck(:kind).uniq).to contain_exactly('task', 'event')
    expect(first.pluck(:id)).not_to eq(second.pluck(:id))
  end

  it 'uses only claimable parent tasks and respects recurring cooldowns' do
    available = task
    reusable = task(status: 'reusable')
    repeatable = task(status: 'repeatable')
    recurring = task(status: 'recurring', days: 7, next_available: Date.today)
    task(status: 'recurring', days: 7, next_available: Date.tomorrow)
    %w[claimed pending completed cancelled denied].each { |status| task(status: status) }
    task(parent_task_id: repeatable.id)
    expect(ids).to contain_exactly(*[available, reusable, repeatable, recurring].map { |row| row.id.to_s })
  end

  it 'excludes reusable claims forever and repeatable claims only while in progress' do
    reusable = task(status: 'reusable')
    repeatable = task(status: 'repeatable')
    task(parent_task_id: reusable.id, claimed_by_id: member.id, status: 'completed')
    claim = task(parent_task_id: repeatable.id, claimed_by_id: member.id, status: 'claimed')
    expect(ids).to be_empty
    claim.set(status: 'pending')
    expect(ids).to be_empty
    claim.set(status: 'completed')
    expect(ids).to eq([repeatable.id.to_s])
  end

  it 'allows multi-use tasks after denied claims and ignores another member claims' do
    reusable = task(status: 'reusable')
    task(parent_task_id: reusable.id, claimed_by_id: member.id, status: 'denied')
    task(parent_task_id: reusable.id, claimed_by_id: create(:member).id, status: 'completed')
    expect(ids).to eq([reusable.id.to_s])
  end

  it 'includes only future open events the member has not already joined' do
    future = event
    event(event_date: Date.today)
    event(event_date: Date.yesterday)
    event(event_date: nil)
    event(status: 'closed')
    event(attendee_ids: [member.id])
    event(attendee_ids: [member.id.to_s])
    expect(home.available_volunteer_opportunities).to contain_exactly(
      id: future.id.to_s, kind: 'event', title: future.title, description: nil,
      creditValue: 1.0, shopName: nil, eventDate: Date.tomorrow.iso8601
    )
  end

  it 'requires all task and event prerequisites, including revoked or missing checkouts' do
    shop = create(:shop)
    first = create(:tool, shop: shop)
    second = create(:tool, shop: shop)
    required_ids = [first.id.to_s, second.id.to_s]
    restricted = task(shop_id: shop.id, prerequisite_tool_ids: required_ids)
    restricted_event = event(shop_id: shop.id, prerequisite_tool_ids: required_ids)
    create(:tool_checkout, member: member, tool: first)
    expect(ids).to be_empty
    checkout = create(:tool_checkout, member: member, tool: second, revoked_at: Time.current)
    expect(ids).to be_empty
    checkout.set(revoked_at: nil)
    expect(ids).to contain_exactly(restricted.id.to_s, restricted_event.id.to_s)
    second.destroy!
    checkout.destroy!
    expect(ids).to be_empty
  end

  it 'preserves hidden-shop redaction without bypassing its prerequisite checks' do
    shop = create(:shop, disabled: true)
    tool = create(:tool, shop: shop, disabled: true)
    task(shop_id: shop.id, prerequisite_tool_ids: [tool.id.to_s])
    expect(ids).to be_empty
    create(:tool_checkout, member: member, tool: tool)
    expect(home.available_volunteer_opportunities.first[:shopName]).to be_nil
  end

  it 'uses linked repair bounty eligibility for reporters, resolved tickets and expired members' do
    ticket = create(:fix_ticket, reporter_id: member.id)
    task(ticket_id: ticket.id)
    expect(ids).to be_empty
    ticket = create(:fix_ticket)
    bounty = task(ticket_id: ticket.id)
    expect(ids).to eq([bounty.id.to_s])
    member.set(expirationTime: 1.day.ago.to_i * 1000)
    expect(ids).to be_empty
    member.set(expirationTime: 1.day.from_now.to_i * 1000)
    ticket.set(status: 'resolved')
    expect(ids).to be_empty
  end

  it 'does not claim, check in, or enqueue notifications while reading recommendations' do
    member
    task
    event
    expect(VolunteerTask).not_to receive(:create!)
    expect(VolunteerSlackCanvasSyncJob).not_to receive(:perform_later)
    expect(Service::SlackConnector).not_to receive(:client)
    expect(Service::SlackConnector).not_to receive(:send_slack_message)
    expect(ids.length).to eq(2)
    expect(VolunteerTask.first.status).to eq('available')
    expect(VolunteerEvent.first.attendee_ids).to be_empty
  end
end
