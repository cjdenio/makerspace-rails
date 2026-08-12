require 'rails_helper'

#https://github.com/mongoid/mongoid-rspec

RSpec.describe Member, type: :model do


  describe "Mongoid validations" do
    it { is_expected.to be_mongoid_document }
    it { is_expected.to be_stored_in(collection: 'members') }

    it { is_expected.to have_fields(:cardID, :firstname, :lastname, :groupName) }
    it { is_expected.to have_field(:status).with_default_value_of('activeMember') }
    it { is_expected.to have_field(:expirationTime).of_type(Integer) }
    it { is_expected.to have_field(:role).with_default_value_of('member') }
    it { is_expected.to have_field(:member_contract_signed_date).of_type(Date) }
    it { is_expected.to have_field(:silence_emails).of_type(Mongoid::Boolean) }
    it { is_expected.to have_field(:subscription).of_type(Mongoid::Boolean).with_default_value_of(false) }
    it { is_expected.to have_fields(:email, :encrypted_password).of_type(String).with_default_value_of("") }
    it { is_expected.to have_field(:reset_password_token).of_type(String) }
    it { is_expected.to have_fields(:reset_password_sent_at, :remember_created_at).of_type(Time) }
  end

  describe "ActiveModel validations" do
    it { is_expected.to validate_presence_of(:firstname) }
    it { is_expected.to validate_presence_of(:lastname) }

    describe "role validation" do
      it "accepts 'admin' as a valid role" do
        member = build(:member, :admin)
        expect(member).to be_valid
      end

      it "accepts 'resource_manager' as a valid role" do
        member = build(:member, :resource_manager)
        expect(member).to be_valid
      end

      it "accepts 'member' as a valid role" do
        member = build(:member)
        expect(member.role).to eq('member')
        expect(member).to be_valid
      end

      it "rejects an unknown role" do
        member = build(:member)
        member.role = 'superuser'
        expect(member).not_to be_valid
        expect(member.errors[:role]).not_to be_empty
      end
    end

    it "accepts pending as a valid member status" do
      expect(build(:member, status: 'pending')).to be_valid
    end
    it { is_expected.to validate_uniqueness_of(:email) }
    it { is_expected.to have_many(:access_cards).as_inverse_of(:member) }
  end

  it "has a valid factory" do
    expect(build(:member)).to be_valid
  end

  it "sanitizes untyped string fields using the runtime value without persisting HTML entities" do
    member = build(:member, firstname: "<b>Jo\u0301 & R&D</b><script>alert(1)</script>", lastname: "2 < 3 & 4 > 1")

    member.valid?

    expect(member.firstname).to eq("Jó & R&Dalert(1)")
    expect(member.lastname).to eq("2 < 3 & 4 > 1")
  end

  it "sanitizes ASCII-8BIT encoded runtime string fields" do
    firstname = "<b>Jo\u0301</b><script>alert(1)</script>".dup.force_encoding(Encoding::ASCII_8BIT)
    member = build(:member, firstname: firstname)

    expect { member.valid? }.not_to raise_error
    expect(member.firstname).to eq("Jóalert(1)")
  end

  it "does not reintroduce entity-encoded markup while sanitizing" do
    member = build(:member, firstname: "Alice &lt;img src=x onerror=alert(1)&gt; Smith")

    member.valid?

    expect(member.firstname).to eq("Alice  Smith")
  end

  it "does not sanitize encrypted credentials, tokens, or external IDs" do
    binary_secret = "\xAA\xBB\xCC\xDD\xEE".dup.force_encoding(Encoding::ASCII_8BIT)
    member = build(:member,
      encrypted_password: binary_secret,
      otp_secret_encrypted: binary_secret,
      session_token: "abc<def>ghi",
      reset_password_token: "abc<def>ghi",
      firebase_uid: "abc<def>ghi",
      customer_id: "abc<def>ghi"
    )

    member.valid?

    expect(member.encrypted_password).to eq(binary_secret)
    expect(member.otp_secret_encrypted).to eq(binary_secret)
    expect(member.session_token).to eq("abc<def>ghi")
    expect(member.reset_password_token).to eq("abc<def>ghi")
    expect(member.firebase_uid).to eq("abc<def>ghi")
    expect(member.customer_id).to eq("abc<def>ghi")
  end

  describe ".search" do
    let(:criteria) { double("scoped criteria") }

    before do
      allow(Member).to receive_message_chain(:collection, :aggregate)
        .and_raise(Mongo::Error::OperationFailure.new("Atlas Search unavailable"))
    end

    it "preserves supplied criteria for email fallback searches" do
      scoped_results = double("scoped email results")

      expect(criteria).to receive(:any_of).with({ email: /member@example\.com/i }).and_return(scoped_results)

      expect(Member.search("member@example.com", criteria)).to eq(scoped_results)
    end

    it "preserves supplied criteria for single-term name fallback searches" do
      scoped_results = double("scoped name results")

      expect(criteria).to receive(:any_of)
        .with({ lastname: /smith/i }, { firstname: /smith/i }, { email: /smith/i })
        .and_return(scoped_results)

      expect(Member.search("smith", criteria)).to eq(scoped_results)
    end

    it "preserves supplied criteria for full-name fallback searches" do
      scoped_results = double("scoped full-name results")

      expect(criteria).to receive(:any_of)
        .with(
          { firstname: /jane/i, lastname: /smith/i },
          { firstname: /smith/i, lastname: /jane/i }
        )
        .and_return(scoped_results)

      expect(Member.search("jane smith", criteria)).to eq(scoped_results)
    end

    it "preserves supplied criteria for Atlas Search result ids" do
      first_member = double("first member", id: BSON::ObjectId.new)
      second_member = double("second member", id: BSON::ObjectId.new)
      result_ids = [first_member.id, second_member.id]

      allow(Member).to receive_message_chain(:collection, :aggregate)
        .and_return(result_ids.map { |id| { _id: id } })
      expect(criteria).to receive(:where)
        .with(id: { :$in => result_ids })
        .and_return([second_member, first_member])

      expect(Member.search("smith", criteria)).to eq([first_member, second_member])
    end
  end

  # Need this because we store things in milliseconds instead of ruby seconds
  def conv_to_ms(time)
    time.to_i * 1000
  end

  context "public methods" do
    let(:member) { create(:member) }
    let(:expired_member) { create(:member, :expired) }
    let(:expired_card) { create(:card, member: expired_member) }

    it "treats a current pending member as active for general membership checks" do
      pending_member = build(:member, :current, status: 'pending')

      expect(pending_member.active_membership_status?).to be(true)
      expect(pending_member.active_unexpired?).to be(true)
      expect(pending_member.fully_active_unexpired?).to be(false)
    end

    describe "Renewing members" do
      it "Adds renewal to Now if member is expired" do
        one_month_later = Time.now + 1.month;
        expired_member.send(:renew=, 1)
        one_month_later_after = Time.now + 1.month;
        # We can't assert the exact time since we measure in ms, the expectation may be off by the
        # assertion by just a few ms. So we define before and after the call, and make sure the result is
        # within those bounds
        expect(expired_member.expirationTime).to be >= conv_to_ms(one_month_later)
        expect(expired_member.expirationTime).to be <= conv_to_ms(one_month_later_after)
      end

      it "Extends membership if not expired" do
        initial_expiration = member.pretty_time
        member.send(:renew=, 10)
        expected_renewal = conv_to_ms(initial_expiration + 10.months)
        expect(member.expirationTime).to eq(expected_renewal)
      end

      it "Lost or stolen card is not reactivated by renewal" do
        expired_card.card_location = "lost"
        expired_card.save

        expect(expired_card.validity).to eq('lost')
        expired_member.send(:renew=, 1)
        new_expiration = expired_member.expirationTime
        expired_card.reload
        expect(expired_card.validity).to eq('lost')
        expect(expired_card.expiry).to eq(new_expiration)
      end
    end

    describe "invoicing" do
      it "delays renewal if no access cards exist" do
        active_member = create(:member, access_cards: create_list(:card, 1))
        expect(member.delay_invoice_operation(:renew=)).to be_truthy
        expect(active_member.delay_invoice_operation(:renew=)).to be_falsy
      end

      it "settles invoices on first access card" do
        invoice_1 = create(:invoice, member: member, transaction_id: "123", quantity: 3)
        initial_expiration = member.pretty_time
        Card.create(uid: "1234", member: member)
        member.reload
        expected_renewal = conv_to_ms(initial_expiration + 3.months)
        expect(member.expirationTime).to eq(expected_renewal)
      end
    end

    describe "address_setter" do 
      it "unpacks and saves address hash as attributes" do 
        member = create(:member)
        address_hash = {
          street: "foo",
          unit: "1",
          city: "bar",
          state: "NH",
          postal_code: "90210"
        }
        member.address = address_hash
        member.reload
        expect(member.address_street).to eq(address_hash[:street])
        expect(member.address_unit).to eq(address_hash[:unit])
        expect(member.address_city).to eq(address_hash[:city])
        expect(member.address_state).to eq(address_hash[:state])
        expect(member.address_postal_code).to eq(address_hash[:postal_code])
      end
    end

    # TODO subscription helpers

    describe "permissions" do
      it "determines if member is allowed by permission" do
        enabled_permission = build(:permission, name: :foo, enabled: true, member_id: nil)
        enabled_permission_2 = build(:permission, name: :bar, enabled: true, member_id: nil)
        disabled_permission = build(:permission, name: :foo, enabled: false, member_id: nil)
        disabled_permission_2 = build(:permission, name: :bar, enabled: false, member_id: nil)
        allowed_member = create(:member, permissions: [enabled_permission, enabled_permission_2] )
        disallowed_member = create(:member, permissions: [disabled_permission, disabled_permission_2] )
        expect(allowed_member.is_allowed?(:foo)).to be_truthy
        expect(allowed_member.is_allowed?(:bar)).to be_truthy
        expect(disallowed_member.is_allowed?(:foo)).to be_falsy
        expect(disallowed_member.is_allowed?(:bar)).to be_falsy
      end

      it "gets permissions for user" do
        enabled_permission = build(:permission, name: :bar, enabled: true, member_id: nil)
        disabled_permission = build(:permission, name: :foo, enabled: false, member_id: nil)
        member = create(:member, permissions: [enabled_permission, disabled_permission] )
        expect(member.get_permissions).to eq({ foo: false, bar: true })
      end

      it "upserts permissions for user" do
        enabled_permission = build(:permission, name: :bar, enabled: true, member_id: nil)
        member = create(:member, permissions: [enabled_permission] )
        expect(member.get_permissions).to eq({ bar: true })
        expect(Permission.all.size).to eq(1)

        member.update_permissions({ bar: false, foo: true })
        member.reload
        expect(member.get_permissions).to eq({ foo: true, bar: false })
        expect(Permission.all.size).to eq(2)
      end

      it "applies default permissions to user" do
        permission1 = create(:default_permission, name: :foo, enabled: false)
        permission2 = create(:default_permission, name: :bar, enabled: true)
        member = create(:member)
        member.reload
        expect(member.get_permissions).to eq({ bar: true, foo: false })
      end
    end
  end

  context "Callbacks" do
    describe "on create" do
      it "schedules only the signup Slack invite" do
        member = build(:member)
        expect(Service::MemberProvisioning).to receive(:invite_slack).with(member)
        expect(MemberSubscriber).not_to receive(:send_google_invite)
        member.save!
      end
    end

    describe "on update" do
      let(:gateway) { double }
      let(:member) { create(:member) }
      let(:expired_member) { create(:member, :expired) }
      let(:expired_card) { create(:card, member: expired_member) }

      it "Updates access card expiration" do
        first_expiration = expired_member.expirationTime
        expect(expired_card.expiry).to eq(first_expiration)

        expired_member.update({ expirationTime: first_expiration + 10})
        expect(expired_card.expiry).to eq(first_expiration + 10)
      end

      it "Doesn't reinvite for normal changes" do
        # Mock this publish so Slack tracking only applies to update and not create
        allow(member).to receive(:publish_create)
        expect_any_instance_of(Service::GoogleDrive).not_to receive(:invite_gdrive)
        expect_any_instance_of(Service::SlackConnector).not_to receive(:invite_to_slack)
        member.update!({ firstname: "foo_changed" })
      end

      it "does not reinvite services if email changes and invalidates external auth/session state" do
        new_email = "foo_changed@test.com"
        previous_email = member.email
        previous_slack_user = SlackUser.create!(
          member: member,
          slack_email: previous_email,
          slack_id: 'U_PREVIOUS'
        )
        member.set(firebase_uid: "firebase-123", session_token: "old-token")

        expect(MemberSubscriber).not_to receive(:send_google_invite)
        expect(MemberSubscriber).not_to receive(:send_slack_invite)

        expect do
          member.update!({ email: new_email })
        end.to have_enqueued_job(MemberProvisioningJob).with(member.id.to_s)

        member.reload
        expect(member.firebase_uid).to be_nil
        expect(member.session_token).to be_present
        expect(member.session_token).not_to eq("old-token")
        expect(member.google_previous_email).to eq(previous_email)
        expect(member.slack_previous_user_id).to eq(previous_slack_user.id)
      end

      it "Updates billing if a customer" do 
        allow(Service::MemberProvisioning).to receive(:invite_slack).and_return(nil)
        customer = create(:member, customer_id: "foo")
        mock_customer_chain = double
        # The subscriber's connect_gateway instance method delegates to
        # ::Service::BraintreeGateway.connect_gateway — stub the class-level method
        allow(Service::BraintreeGateway).to receive(:connect_gateway).and_return(gateway)
        expect(gateway).to receive(:customer).and_return(mock_customer_chain)
        expect(mock_customer_chain).to receive(:update).with(
          "foo", 
          first_name: "foo_changed", 
          last_name: customer.lastname
        )
        customer.update!({ firstname: "foo_changed" })
      end

      it "Doesn't update billing if not a customer" do 
        allow_any_instance_of(Service::BraintreeGateway).to receive(:connect_gateway).and_return(gateway)
        expect(gateway).not_to receive(:customer)
        member.update!({ firstname: "foo_changed" })
      end

    it "disbands the household when the primary renews with an individual member invoice" do
      primary = create(:member, expirationTime: 1.month.from_now.to_i * 1000)
      secondary = create(:member, expirationTime: primary.expirationTime, silence_emails: true)
      group = create(:group, member: primary, groupRep: primary.fullname, groupName: primary.id.to_s, expiry: primary.expirationTime)
      primary.update!(groupName: group.groupName)
      secondary.update!(groupName: group.groupName)
      SlackUser.create!(member_id: primary.id, slack_id: "U_PRIMARY")
      SlackUser.create!(member_id: secondary.id, slack_id: "U_SECONDARY")
      allow(::Service::SlackConnector).to receive(:send_slack_message)
      mail_delivery = instance_double(ActionMailer::MessageDelivery, deliver_later: true)
      allow(MemberMailer).to receive(:household_disbanded).and_return(mail_delivery)

      individual_invoice = build(:invoice, member: primary, resource_id: primary.id.to_s, resource_class: "member", plan_id: "standard-membership-one-month-recurring")
      primary.current_invoice_operation = individual_invoice
      primary.update!(expirationTime: 2.months.from_now.to_i * 1000)

      expect(Group.where(id: group.id).count).to eq(0)
      expect(primary.reload.groupName).to be_nil
      expect(secondary.reload.groupName).to be_nil
      expect(::Service::SlackConnector).to have_received(:send_slack_message).with(/individual membership plan/, "U_PRIMARY")
      expect(::Service::SlackConnector).to have_received(:send_slack_message).with(/elect a new membership plan/, "U_SECONDARY")
      expect(MemberMailer).to have_received(:household_disbanded).with(primary.id.to_s, primary.id.to_s, true)
      expect(MemberMailer).to have_received(:household_disbanded).with(secondary.id.to_s, primary.id.to_s, false)
      expect(mail_delivery).to have_received(:deliver_later).twice
    end

    it "keeps the household together when the primary expiration is synced from a member-backed household invoice" do
      primary = create(:member, expirationTime: 1.month.from_now.to_i * 1000)
      secondary = create(:member, expirationTime: primary.expirationTime)
      group = create(:group, member: primary, groupRep: primary.fullname, groupName: primary.id.to_s, expiry: primary.expirationTime)
      primary.update!(groupName: group.groupName)
      secondary.update!(groupName: group.groupName)
      household_invoice = build(:invoice, member: primary, resource_id: primary.id.to_s, resource_class: "member", plan_id: "household-membership-one-month-recurring")

      primary.current_invoice_operation = household_invoice
      primary.update!(expirationTime: 2.months.from_now.to_i * 1000)

      expect(Group.where(id: group.id).exists?).to be(true)
      expect(group.reload.expiry).to eq(primary.reload.expirationTime)
      expect(secondary.reload.groupName).to eq(group.groupName)
      expect(secondary.expirationTime).to eq(primary.expirationTime)
    end

    it "syncs non-invoice primary expiration edits instead of disbanding the household" do
      primary = create(:member, expirationTime: 1.month.from_now.to_i * 1000)
      secondary = create(:member, expirationTime: primary.expirationTime)
      group = create(:group, member: primary, groupRep: primary.fullname, groupName: primary.id.to_s, expiry: primary.expirationTime)
      primary.update!(groupName: group.groupName)
      secondary.update!(groupName: group.groupName)

      primary.update!(expirationTime: 2.months.from_now.to_i * 1000)

      expect(Group.where(id: group.id).exists?).to be(true)
      expect(group.reload.expiry).to eq(primary.reload.expirationTime)
      expect(secondary.reload.groupName).to eq(group.groupName)
      expect(secondary.expirationTime).to eq(primary.expirationTime)
    end

    it "cancels the active household subscription before destroying the group" do
      primary = create(:member, expirationTime: 1.month.from_now.to_i * 1000)
      secondary = create(:member, expirationTime: primary.expirationTime)
      group = create(:group, member: primary, groupRep: primary.fullname, groupName: primary.id.to_s, expiry: primary.expirationTime)
      group.update!(subscription_id: "household_sub_123", subscription: true)
      primary.update!(groupName: group.groupName)
      secondary.update!(groupName: group.groupName)
      allow(::Service::SlackConnector).to receive(:send_slack_message)
      mail_delivery = instance_double(ActionMailer::MessageDelivery, deliver_later: true)
      allow(MemberMailer).to receive(:household_disbanded).and_return(mail_delivery)
      allow(::Service::BraintreeGateway).to receive(:connect_gateway).and_return(gateway)
      allow(::BraintreeService::Subscription).to receive(:cancel)

      individual_invoice = build(:invoice, member: primary, resource_id: primary.id.to_s, resource_class: "member", plan_id: "standard-membership-one-month-recurring")
      primary.current_invoice_operation = individual_invoice
      primary.update!(expirationTime: 2.months.from_now.to_i * 1000)

      expect(::BraintreeService::Subscription).to have_received(:cancel).with(gateway, "household_sub_123")
      expect(Group.where(id: group.id).count).to eq(0)
    end
    end

    describe "on destroy" do 
      it "cancels its subscription if subscription_id exists" do 
        member = create(:member, subscription_id: "124")
        expect(BraintreeService::Subscription).to receive(:cancel).with(anything, "124")
        member.destroy
      end
    
      it "Doesnt touch subscription if subscription_id doesn't exist" do 
        member = create(:member)
        expect(BraintreeService::Subscription).not_to receive(:cancel).with(anything, "124")
        member.destroy
      end

      it "Deletes rentals if rentals exists" do 
        member = create(:member)
        create(:rental, member: member)
        create(:rental, member: member)
        expect(Rental.all.length).to eq(2)
        member.destroy
        expect(Rental.all.length).to eq(0)
      end
    end
  end

  describe "#send_renewal_slack_message" do
    # Regression for a key-collision bug: enque_message's default uniquifier
    # is derived only from the calling method name + Current.request_id.
    # Both the member-DM and management-channel calls happen within this
    # one method in the same request, so without distinct, explicit
    # uniquifiers, the second REDIS.set silently overwrote the first,
    # losing one of the two renewal notifications every time.
    #
    # NOTE: Current.request_id is only ever set by SetCurrentRequestDetails
    # in real requests — in a plain model spec nothing sets it, so it stays
    # nil for the whole suite run unless set explicitly here. Without an
    # explicit, unique value per test, the wildcard lookup below would match
    # every key in Redis (since nil.to_s + ".*" == ".*"), including leftover
    # keys from any other test in the suite — exactly what caused this test
    # to see 6 channels instead of 2 once other tests in the suite also
    # enqueued messages with the same unset request_id.
    around do |example|
      Current.request_id = SecureRandom.uuid
      example.run
      REDIS.keys("#{Current.request_id}.*").each { |key| REDIS.del(key) }
      Current.request_id = nil
    end

    it "queues both the member DM and management channel notification under distinct keys" do
      member = create(:member)
      slack_user = SlackUser.create!(member_id: member.id, slack_id: "U_TEST_MEMBER")

      member.send_renewal_slack_message

      enqueued = Service::SlackConnector.get_enqueued_messages("#{Current.request_id}.*")
      channels = enqueued.values.map { |payload| JSON.parse(payload)["channel"] }

      expect(channels).to include(slack_user.slack_id)
      expect(channels).to include(Service::SlackConnector.members_relations_channel)
      expect(channels.size).to eq(2)
    end

    it "queues only the management channel notification when the member has no SlackUser" do
      member = create(:member)

      member.send_renewal_slack_message

      enqueued = Service::SlackConnector.get_enqueued_messages("#{Current.request_id}.*")
      channels = enqueued.values.map { |payload| JSON.parse(payload)["channel"] }

      expect(channels).to eq([Service::SlackConnector.members_relations_channel])
    end
  end

  describe "#find_subscribed_resource" do
    # Regression for the gap flagged on #92: once Group gained its own
    # subscription_id (for household billing), find_subscribed_resource
    # still only checked the member's own subscription_id and rentals —
    # never the member's household group. A primary household member
    # managing their own household_* subscription via self-service
    # (Billing::SubscriptionsController#verify_own_subscription) would
    # get a 404 without this.
    it "finds the member's household group subscription when the member's own and rental subscriptions don't match" do
      member = create(:member)
      group = create(:group, member: member, groupRep: member.fullname, groupName: member.id.to_s)
      group.update!(subscription_id: "household_sub_123")
      member.update!(groupName: group.groupName)

      expect(member.find_subscribed_resource("household_sub_123")).to eq(group)
    end

    it "still prefers the member's own subscription over the group's when both are present" do
      member = create(:member, subscription_id: "member_sub_123")
      group = create(:group, member: member, groupRep: member.fullname, groupName: member.id.to_s)
      group.update!(subscription_id: "household_sub_123")
      member.update!(groupName: group.groupName)

      expect(member.find_subscribed_resource("member_sub_123")).to eq(member)
    end

    it "does not expose the household subscription to a secondary member" do
      primary = create(:member)
      secondary = create(:member)
      group = create(:group, member: primary, groupRep: primary.fullname, groupName: primary.id.to_s)
      group.update!(subscription_id: "household_sub_123")
      secondary.update!(groupName: group.groupName)

      expect(secondary.find_subscribed_resource("household_sub_123")).to be_nil
    end

    it "returns nil when neither the member, rentals, nor group match" do
      member = create(:member)
      expect(member.find_subscribed_resource("nonexistent_sub")).to be_nil
    end
  end

  describe "#timeout_in" do
    # Overrides Devise::Models::Timeoutable#timeout_in to look up the idle
    # session timeout fresh from SystemConfig on every call, rather than a
    # value fixed once at boot (see config/initializers/devise.rb and the
    # PROD_CUTOVER_CHECKLIST discussion of #103). These specs cover the
    # fallback/clamping behavior directly since Devise itself only calls
    # this method internally on each authenticated request.
    it "defaults to 30 minutes when devise_timeout_minutes is not configured" do
      expect(create(:member).timeout_in).to eq(30.minutes)
    end

    it "uses the configured value when set to a valid positive integer" do
      SystemConfig.set('devise_timeout_minutes', '45')
      expect(create(:member).timeout_in).to eq(45.minutes)
    end

    it "clamps to a 1 minute minimum when the configured value is zero or negative" do
      SystemConfig.set('devise_timeout_minutes', '0')
      expect(create(:member).timeout_in).to eq(1.minute)

      SystemConfig.set('devise_timeout_minutes', '-5')
      expect(create(:member).timeout_in).to eq(1.minute)
    end

    it "falls back to 30 minutes when the configured value is not a valid integer" do
      SystemConfig.set('devise_timeout_minutes', 'not-a-number')
      expect(create(:member).timeout_in).to eq(30.minutes)
    end
  end
end
