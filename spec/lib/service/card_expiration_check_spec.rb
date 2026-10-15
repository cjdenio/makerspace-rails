require 'rails_helper'

RSpec.describe Service::CardExpirationCheck do
  let(:redis_strings) { {} }
  let(:redis_hashes) { Hash.new { |hash, key| hash[key] = {} } }
  let(:customer_gateway) { double('Braintree customer gateway') }
  let(:gateway) { double('Braintree gateway', customer: customer_gateway) }
  let(:search_field) { double('expiration search field') }
  let(:search) { double('customer search', credit_card_expiration_date: search_field) }
  let(:at) { Time.find_zone!('America/New_York').local(2026, 8, 1, 8, 0) }

  before do
    allow(REDIS).to receive(:set) do |key, value, ex:|
      redis_strings[key] = value.to_s
      expect(ex).to be_positive
      'OK'
    end
    allow(REDIS).to receive(:get) { |key| redis_strings[key] }
    allow(REDIS).to receive(:del) { |key| redis_hashes.delete(key); redis_strings.delete(key) }
    allow(REDIS).to receive(:hset) { |key, field, value| redis_hashes[key][field] = value }
    allow(REDIS).to receive(:hget) { |key, field| redis_hashes[key][field] }
    allow(REDIS).to receive(:expire) { |_key, ttl| expect(ttl).to be_positive; true }
    allow(search_field).to receive(:is)
    allow(Service::SlackConnector).to receive(:members_relations_channel).and_return('members-relations')
    allow(Service::SlackConnector).to receive(:send_slack_message)
  end

  def card(type, month: '08', year: '2026')
    double('card', card_type: type, expiration_month: month, expiration_year: year)
  end

  def customer(id, cards)
    double('customer', id: id, credit_cards: cards)
  end

  it 'searches Braintree, filters active members with aggregation, notifies Slack, and caches this month' do
    active = create(
      :member,
      customer_id: 'customer-active',
      subscription: true,
      status: 'activeMember',
      expirationTime: (at + 2.months).to_i * 1000,
      firstname: 'Active',
      lastname: 'Member'
    )
    SlackUser.create!(member: active, slack_id: 'U-ACTIVE')
    no_slack = create(
      :member,
      customer_id: 'customer-no-slack',
      subscription: true,
      status: 'activeMember',
      expirationTime: (at + 2.months).to_i * 1000
    )
    create(
      :member,
      customer_id: 'customer-inactive',
      subscription: true,
      status: 'inactive',
      expirationTime: (at + 2.months).to_i * 1000
    )
    customers = [
      customer('customer-active', [card('Visa'), card('Discover'), card('Mastercard', month: '09')]),
      customer('customer-no-slack', [card('American Express')]),
      customer('customer-inactive', [card('Visa')])
    ]
    allow(customer_gateway).to receive(:search).and_yield(search).and_return(customers)

    records = described_class.run!(at: at, gateway: gateway)

    expect(search_field).to have_received(:is).with('08/26')
    expect(records.map { |record| record[:customer_id] }).to contain_exactly('customer-active', 'customer-no-slack')
    expect(records.find { |record| record[:customer_id] == 'customer-active' }[:card_types]).to eq('Visa, Discover')
    expect(described_class.expiring_member_count(at: at)).to eq(2)
    expect(described_class.card_types_for_member(active.id, at: at)).to eq('Visa, Discover')
    expect(described_class.card_types_for_member(no_slack.id, at: at)).to eq('American Express')
    expect(Service::SlackConnector).to have_received(:send_slack_message)
      .with(a_string_including('visa, discover', 'update your payment methods'), 'U-ACTIVE')
    expect(Service::SlackConnector).to have_received(:send_slack_message)
      .with(a_string_including('customer-active', 'Member notified via Slack: yes'), 'members-relations')
    expect(Service::SlackConnector).to have_received(:send_slack_message)
      .with(a_string_including('customer-no-slack', 'Member notified via Slack: no'), 'members-relations')
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
      .with(a_string_including('customer-inactive'), anything)
  end

  it 'clears stale member records and caches zero when no active member matches' do
    key = 'card_expiration_check:v1:2026-08:members'
    redis_hashes[key]['old-member'] = 'Visa'
    customers = [customer('missing-customer', [card('Visa')])]
    allow(customer_gateway).to receive(:search).and_yield(search).and_return(customers)

    expect(described_class.run!(at: at, gateway: gateway)).to eq([])

    expect(described_class.expiring_member_count(at: at)).to eq(0)
    expect(redis_hashes[key]).to eq({})
    expect(Service::SlackConnector).not_to have_received(:send_slack_message)
  end

  it 'includes active Braintree members backed by subscription_id when the legacy flag is false' do
    member = create(
      :member,
      customer_id: 'customer-subscription-id',
      subscription: false,
      subscription_id: 'subscription-123',
      status: 'activeMember',
      expirationTime: (at + 2.months).to_i * 1000
    )
    customers = [customer('customer-subscription-id', [card('Visa')])]
    allow(customer_gateway).to receive(:search).and_yield(search).and_return(customers)

    records = described_class.run!(at: at, gateway: gateway)

    expect(records.map { |record| record[:customer_id] }).to eq(['customer-subscription-id'])
    expect(described_class.expiring_member_count(at: at)).to eq(1)
    expect(described_class.card_types_for_member(member.id, at: at)).to eq('Visa')
  end

  it 'includes subscribed pending members with a future expiration' do
    member = create(
      :member,
      customer_id: 'customer-pending',
      subscription: true,
      status: 'pending',
      expirationTime: (at + 2.months).to_i * 1000
    )
    customers = [customer('customer-pending', [card('Discover')])]
    allow(customer_gateway).to receive(:search).and_yield(search).and_return(customers)

    records = described_class.run!(at: at, gateway: gateway)

    expect(records.map { |record| record[:customer_id] }).to eq(['customer-pending'])
    expect(described_class.expiring_member_count(at: at)).to eq(1)
    expect(described_class.card_types_for_member(member.id, at: at)).to eq('Discover')
  end
end
