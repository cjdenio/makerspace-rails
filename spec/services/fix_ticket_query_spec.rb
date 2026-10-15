require 'rails_helper'

RSpec.describe FixTicketQuery do
  before { allow(REDIS).to receive(:set).and_return(true) }

  it 'bounds related-record reads independently of page size and redacts detail actors' do
    viewer = create(:member, :admin, :current)
    people = Array.new(3) { create(:member, :current) }
    shop = create(:shop)
    tool = Tool.create!(shop: shop, name: 'Hidden tool', disabled: true)
    bounty = VolunteerTask.create!(title: 'Repair', description: 'Repair tool', created_by_id: viewer.id)
    reward = VolunteerCredit.create!(member_id: people.first.id, issued_by_id: viewer.id, description: 'Helpful report')
    tickets = Array.new(100) { create(:fix_ticket, reporter_id: people.first.id, shop_id: shop.id, tool_id: tool.id, bounty_id: bounty.id, reward_id: reward.id, assignee_ids: people.map(&:id)) }
    commands = []
    subscriber = Object.new
    subscriber.define_singleton_method(:started) { |event| commands << event.command_name if %w[find aggregate count getMore].include?(event.command_name) }
    subscriber.define_singleton_method(:succeeded) { |_| }
    subscriber.define_singleton_method(:failed) { |_| }
    client = Mongoid.default_client
    client.subscribe(Mongo::Monitoring::COMMAND, subscriber)
    begin
      [1, 25, 100].each do |size|
        commands.clear
        page = described_class.call(viewer, page_size: size)
        expect(commands.length).to be_between(1, 7)
        expect(page[:total]).to eq(100)
        expect(page[:tickets].length).to eq(size)
        expect(page[:tickets].first).to include(toolHidden: true, rewardStatus: 'pending')
        expect(page[:tickets].first[:assignees].map { |p| p[:name] }).to eq(people.map(&:fullname))
      end
      ticket = tickets.first
      [people.first, people.last].each do |actor|
        FixTicketEvent.create!(ticket_id: ticket.id, actor_id: actor.id, kind: 'note', note: 'Details', revision: actor == people.first ? 1 : 2)
      end
      detail = FixTicketPresenter.ticket(ticket, viewer, detail: true)
      expect(detail[:events].map { |event| event[:actor] }).to eq(['Reporter', people.last.fullname])
      expect(described_class.call(viewer, page: 200)).to include(tickets: [], total: 100)
      expect(described_class.call(viewer, statuses: ['resolved'])).to include(tickets: [], total: 0)
    ensure
      client.unsubscribe(Mongo::Monitoring::COMMAND, subscriber)
    end
  end
end
