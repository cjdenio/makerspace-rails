require "rails_helper"

RSpec.describe CheckoutRequestDigest do
  let(:now) { Time.zone.local(2026, 10, 12, 10, 30) }
  let(:shop) { create(:shop, name: "Woodworking") }
  let(:metal) { create(:shop, name: "Metalworking") }
  let(:bandsaw) { create(:tool, shop: shop, name: "Laguna Bandsaw") }
  let(:drill) { create(:tool, shop: shop, name: "Drill Press") }
  let(:plasma) { create(:tool, shop: metal, name: "CNC Plasma Cutter") }
  let(:lathe) { create(:tool, shop: metal, name: "Lathe") }
  let(:pat) { create(:member, :current, firstname: "Pat", lastname: "Member") }
  let(:lee) { create(:member, :current, firstname: "Lee", lastname: "Davis") }
  let(:redis_keys) { {} }

  def link_slack(member, slack_id)
    SlackUser.create!(member: member, slack_id: slack_id, slack_email: member.email)
    member
  end

  def woodworking_manager(slack_id = "UWOOD")
    link_slack(create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s]), slack_id)
  end

  def request_for(member, tool, days_ago, hours_ago: 0)
    ToolCheckoutRequest.create!(member: member, tool: tool, request_date: now - days_ago.days - hours_ago.hours)
  end

  before do
    allow(REDIS).to receive(:set) do |key, value, **options|
      next false if options[:nx] && redis_keys.key?(key)

      redis_keys[key] = value.to_s
      true
    end
    allow(REDIS).to receive(:get) { |key| redis_keys[key] }
    allow(REDIS).to receive(:del) { |key| redis_keys.delete(key) }
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::ErrorReporter).to receive(:notify)
  end

  describe ".message" do
    it "lists each requester with their tools and how long each request has waited, oldest requester first" do
      requests = [request_for(lee, lathe, 1), request_for(pat, plasma, 3), request_for(pat, bandsaw, 12)]

      expect(described_class.message(requests, now: now)).to eq(<<~TEXT.chomp)
        Open checkout requests (3)

        #{CheckoutDisplay.escape(pat.fullname)}
          • Laguna Bandsaw (Woodworking) – 12 days old
          • CNC Plasma Cutter (Metalworking) – 3 days old
        #{CheckoutDisplay.escape(lee.fullname)}
          • Lathe (Metalworking) – 1 day old

        use /checkout → View open requests, or use the Member Portal
        #{described_class::DONE_IN_PERSON}
      TEXT
    end

    it "says less than a day old for a request made today" do
      expect(described_class.message([request_for(lee, lathe, 0)], now: now)).to include("less than a day old")
    end

    it "caps the list and points to the portal for the rest" do
      requests = Array.new(described_class::MAX_REQUESTERS + 2) do |index|
        request_for(create(:member, :current), lathe, index + 1)
      end

      text = described_class.message(requests, now: now)

      expect(text).to include("(#{requests.size})", "and 2 more members, see the Member Portal.")
    end
  end

  describe ".deliver_all!" do
    it "sends one roll-up of ALL open requests when there is a new request, including older ones" do
      woodworking_manager
      request_for(pat, bandsaw, 3)
      request_for(lee, drill, 0, hours_ago: 2)

      described_class.deliver_all!(now: now)

      expect(Service::SlackConnector).to have_received(:send_slack_message)
        .with(a_string_including("Open checkout requests (2)", "Laguna Bandsaw", "3 days old", "Drill Press"), "UWOOD").once
    end

    it "scopes each person's roll-up to the requests they can act on" do
      woodworking_manager("UWOOD")
      link_slack(create(:member, :resource_manager, :current, resource_manager_shop_ids: [metal.id.to_s]), "UMETAL")
      approver = create(:member, :current, member_contract_signed_date: Date.current)
      CheckoutApprover.create!(member: approver, tool_ids: [bandsaw.id.to_s])
      link_slack(approver, "UTOOL")
      request_for(pat, bandsaw, 0, hours_ago: 1)
      request_for(pat, plasma, 0, hours_ago: 1)

      described_class.deliver_all!(now: now)

      expect(Service::SlackConnector).to have_received(:send_slack_message)
        .with(a_string_starting_with("Open checkout requests (1)").and(include("Laguna Bandsaw"))
                .and(satisfy { |text| !text.include?("CNC") }), "UWOOD")
      expect(Service::SlackConnector).to have_received(:send_slack_message)
        .with(a_string_starting_with("Open checkout requests (1)").and(include("CNC Plasma Cutter")), "UMETAL")
      expect(Service::SlackConnector).to have_received(:send_slack_message)
        .with(a_string_starting_with("Open checkout requests (1)").and(include("Laguna Bandsaw")), "UTOOL")
    end

    it "sends nothing when no request is new and none is exactly 5, 10, 15... days old" do
      woodworking_manager
      [3, 4, 6, 7, 9, 11, 12].each { |days| request_for(create(:member, :current), bandsaw, days) }

      described_class.deliver_all!(now: now)

      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end

    [5, 10, 15].each do |days|
      it "sends the roll-up when a request reaches #{days} days, even with nothing new" do
        woodworking_manager
        request_for(pat, bandsaw, days)
        request_for(lee, drill, days - 2)

        described_class.deliver_all!(now: now)

        expect(Service::SlackConnector).to have_received(:send_slack_message)
          .with(a_string_including("Open checkout requests (2)", "#{days} days old", "#{days - 2} days old"), "UWOOD").once
      end
    end

    it "does not message on days between milestones" do
      woodworking_manager
      request_for(pat, bandsaw, 5)

      described_class.deliver_all!(now: now)
      expect(Service::SlackConnector).to have_received(:send_slack_message).once

      (1..4).each { |offset| described_class.deliver_all!(now: now + offset.days) }
      expect(Service::SlackConnector).to have_received(:send_slack_message).once

      described_class.deliver_all!(now: now + 5.days)
      expect(Service::SlackConnector).to have_received(:send_slack_message).twice
    end

    it "sends at most one digest a day, then only again for something new" do
      woodworking_manager
      request_for(pat, bandsaw, 0, hours_ago: 3)

      described_class.deliver_all!(now: now)
      described_class.deliver_all!(now: now + 2.hours)
      expect(Service::SlackConnector).to have_received(:send_slack_message).once

      described_class.deliver_all!(now: now + 1.day)
      expect(Service::SlackConnector).to have_received(:send_slack_message).once

      ToolCheckoutRequest.create!(member: lee, tool: drill, request_date: now + 1.day - 3.hours)
      described_class.deliver_all!(now: now + 2.days)
      expect(Service::SlackConnector).to have_received(:send_slack_message).twice
    end

    it "leaves out requests an approver could not act on, such as one from an expired member" do
      woodworking_manager
      expired = create(:member, :expired)
      request_for(expired, bandsaw, 0, hours_ago: 1)
      described_class.deliver_all!(now: now)
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)

      request_for(pat, drill, 0, hours_ago: 1)
      described_class.deliver_all!(now: now)

      expect(Service::SlackConnector).to have_received(:send_slack_message)
        .with(a_string_including("(1)", "Drill Press").and(satisfy { |text| !text.include?("Laguna") }), "UWOOD").once
    end

    describe "replacing the previous digest" do
      let(:first_post) { double(ts: "111.1", channel: "DAPPROVER") }
      let(:second_post) { double(ts: "222.2", channel: "DAPPROVER") }

      before do
        allow(Service::SlackConnector).to receive(:update_slack_message)
        @manager = woodworking_manager
      end

      it "edits the previous digest into a stub when a newer one is sent, and always posts the new one fresh" do
        allow(Service::SlackConnector).to receive(:send_slack_message).and_return(first_post, second_post)
        request_for(pat, bandsaw, 0, hours_ago: 1)
        described_class.deliver_all!(now: now)
        expect(Service::SlackConnector).not_to have_received(:update_slack_message)

        ToolCheckoutRequest.create!(member: lee, tool: drill, request_date: now + 1.day - 1.hour)
        described_class.deliver_all!(now: now + 1.day)

        expect(Service::SlackConnector).to have_received(:send_slack_message).twice
        expect(Service::SlackConnector).to have_received(:update_slack_message)
          .with("DAPPROVER", "111.1", described_class::REPLACED_TEXT, resolved_channel: true).once
        expect(JSON.parse(redis_keys.fetch("checkout_request_digest_message:#{@manager.id}")))
          .to eq("channel" => "DAPPROVER", "ts" => "222.2")
      end

      it "still sends the new digest and remembers it when editing the old one fails" do
        allow(Service::SlackConnector).to receive(:send_slack_message).and_return(first_post, second_post)
        allow(Service::SlackConnector).to receive(:update_slack_message).and_raise("message_not_found")
        request_for(pat, bandsaw, 0, hours_ago: 1)
        described_class.deliver_all!(now: now)
        ToolCheckoutRequest.create!(member: lee, tool: drill, request_date: now + 1.day - 1.hour)

        described_class.deliver_all!(now: now + 1.day)

        expect(Service::SlackConnector).to have_received(:send_slack_message).twice
        expect(Service::ErrorReporter).to have_received(:notify).once
        expect(redis_keys.values.grep(/222\.2/)).not_to be_empty
      end

      it "does not touch the previous message when Slack returns no timestamp" do
        request_for(pat, bandsaw, 0, hours_ago: 1)
        described_class.deliver_all!(now: now)
        ToolCheckoutRequest.create!(member: lee, tool: drill, request_date: now + 1.day - 1.hour)

        described_class.deliver_all!(now: now + 1.day)

        expect(Service::SlackConnector).not_to have_received(:update_slack_message)
      end
    end

    it "sends nothing to someone with no open requests, to the requester, or to plain admin and board members" do
      link_slack(create(:member, :resource_manager, :current, resource_manager_shop_ids: [metal.id.to_s]), "UMETAL")
      link_slack(create(:member, :admin, :current), "UADMIN")
      link_slack(create(:member, :board_member, :current), "UBOARD")
      requester_manager = create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
      link_slack(requester_manager, "UOWN")
      request_for(requester_manager, bandsaw, 0, hours_ago: 1)

      described_class.deliver_all!(now: now)

      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end

    it "ignores resolved requests and skips recipients without Slack or with suppressed notifications" do
      woodworking_manager
      create(:member, :resource_manager, :current, resource_manager_shop_ids: [shop.id.to_s])
      link_slack(create(:member, :resource_manager, :current, status: "suspended",
                        resource_manager_shop_ids: [shop.id.to_s]), "USUSPENDED")
      request_for(pat, bandsaw, 40)
      request_for(lee, bandsaw, 0, hours_ago: 1).update!(status: "deleted")

      described_class.deliver_all!(now: now)
      expect(Service::SlackConnector).to have_received(:send_slack_message)
        .with(a_string_including("(1)", "40 days old"), "UWOOD").once
      expect(Service::SlackConnector).to have_received(:send_slack_message).once
    end

    it "releases the day's key on a failed send so a later run retries, and keeps going for other recipients" do
      woodworking_manager("UONE")
      woodworking_manager("UTWO")
      request_for(pat, bandsaw, 0, hours_ago: 3)
      attempts = Hash.new(0)
      allow(Service::SlackConnector).to receive(:send_slack_message) do |_text, slack_id|
        attempts[slack_id] += 1
        raise "Slack unavailable" if slack_id == "UTWO" && attempts[slack_id] == 1
      end

      described_class.deliver_all!(now: now)
      expect(Service::ErrorReporter).to have_received(:notify).once
      described_class.deliver_all!(now: now + 1.hour)

      expect(attempts).to eq("UONE" => 1, "UTWO" => 2)
    end
  end
end
