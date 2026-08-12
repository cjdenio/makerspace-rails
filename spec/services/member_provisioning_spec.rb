require 'rails_helper'

RSpec.describe Service::MemberProvisioning do
  before do
    allow(MemberSubscriber).to receive(:send_slack_invite)
    allow(Service::AuditLogger).to receive(:log)
    allow(Honeybadger).to receive(:notify)
    allow(ENV).to receive(:[]).and_call_original
  end

  def active_member_with_card(status: 'activeMember')
    member = create(
      :member,
      status: status,
      expirationTime: 1.month.from_now.to_i * 1000
    )
    Card.create!(member: member, uid: SecureRandom.hex(6))
    member.reload
  end

  describe 'activation eligibility' do
    it 'requires a future expiration, a usable fob, and a non-blocked status' do
      %w[activeMember nonMember suspended].each do |status|
        expect(active_member_with_card(status: status)).to be_provisioning_eligible
      end

      %w[revoked inactive].each do |status|
        expect(active_member_with_card(status: status)).not_to be_provisioning_eligible
      end

      member = active_member_with_card
      member.access_cards.first.set(validity: 'lost')
      expect(member.reload).not_to be_provisioning_eligible

      member.access_cards.first.set(validity: 'activeMember')
      member.set(expirationTime: 1.day.ago.to_i * 1000)
      expect(member.reload).not_to be_provisioning_eligible
    end
  end

  describe 'activation callbacks' do
    it 'queues reconciliation when expiration or status changes' do
      member = create(:member)

      expect do
        member.update!(expirationTime: 2.months.from_now.to_i * 1000)
      end.to have_enqueued_job(MemberProvisioningJob).with(member.id.to_s)

      expect do
        member.update!(status: 'suspended')
      end.to have_enqueued_job(MemberProvisioningJob).with(member.id.to_s)
    end

    it 'queues reconciliation when a fob is issued or its usability changes' do
      member = create(:member)
      card = nil

      expect do
        card = Card.create!(member: member, uid: SecureRandom.hex(6))
      end.to have_enqueued_job(MemberProvisioningJob).with(member.id.to_s)

      expect do
        card.update!(card_location: 'lost')
      end.to have_enqueued_job(MemberProvisioningJob).with(member.id.to_s)
    end
  end

  describe '.invite_slack' do
    it 'uses a matching SlackUser email as invitation confirmation without reinviting' do
      member = create(:member, email: 'Member@Example.com')
      SlackUser.create!(
        slack_email: 'member@example.com',
        slack_id: 'U123',
        name: 'member'
      )
      allow(described_class).to receive(:lookup_slack_user).with(member.email).and_return(
        'id' => 'U123',
        'name' => 'member',
        'deleted' => false,
        'profile' => { 'email' => member.email }
      )
      expect(Service::SlackConnector).not_to receive(:invite_to_slack)

      result = described_class.invite_slack(member)

      expect(result[:status]).to eq(:confirmed)
      member.reload
      expect(member.slack_invite_source).to eq('slack_user_record')
      expect(member.slack_invite_confirmed_at).to be_present
    end

    it 'reinvites when the matching local SlackUser has been deactivated remotely' do
      member = create(:member, email: 'member@example.com')
      SlackUser.create!(
        slack_email: member.email,
        slack_id: 'U123',
        name: 'member'
      )
      allow(described_class).to receive(:lookup_slack_user).with(member.email).and_return(
        'id' => 'U123',
        'deleted' => true,
        'profile' => { 'email' => member.email }
      )
      allow(Service::SlackConnector).to receive(:invite_to_slack).and_return(ok: true)
      allow(Service::SlackConnector).to receive(:new_signup_invite_mode).and_return('full_member')

      result = described_class.invite_slack(member)

      expect(result[:status]).to eq(:invited)
      expect(Service::SlackConnector).to have_received(:invite_to_slack).with(
        member.email,
        member.lastname,
        member.firstname
      )
    end

    it 'confirms a live Slack user and rebuilds its local record when none exists' do
      member = create(:member, email: 'member@example.com')
      allow(described_class).to receive(:lookup_slack_user).with(member.email).and_return(
        'id' => 'U123',
        'name' => 'member',
        'deleted' => false,
        'profile' => { 'email' => member.email, 'real_name' => member.fullname }
      )
      expect(Service::SlackConnector).not_to receive(:invite_to_slack)

      result = described_class.invite_slack(member)

      expect(result[:status]).to eq(:confirmed)
      expect(SlackUser.find_by(slack_id: 'U123')).to have_attributes(
        member_id: member.id,
        slack_email: member.email
      )
    end

    it 'revokes and detaches the previous Slack identity before inviting the current email' do
      member = create(:member, email: 'current@example.com')
      previous_user = SlackUser.create!(
        member: member,
        slack_email: 'previous@example.com',
        slack_id: 'U_PREVIOUS'
      )
      member.set(slack_previous_user_id: previous_user.id)
      admin_client = double
      allow(Service::SlackConnector).to receive(:admin_client)
        .with('users.admin.setInactive')
        .and_return(admin_client)
      expect(admin_client).to receive(:users_admin_setInactive)
        .with(user: 'U_PREVIOUS')
        .ordered
      allow(described_class).to receive(:lookup_slack_user).with(member.email).and_return(nil)
      expect(Service::SlackConnector).to receive(:invite_to_slack)
        .with(member.email, member.lastname, member.firstname)
        .ordered
        .and_return(ok: true)
      allow(Service::SlackConnector).to receive(:new_signup_invite_mode).and_return('full_member')

      result = described_class.invite_slack(member)

      expect(result[:status]).to eq(:invited)
      expect(previous_user.reload.member_id).to be_nil
      expect(previous_user.invalidated_at).to be_present
      expect(previous_user.invalidation_reason).to eq('member_email_changed')
      expect(member.reload.slack_previous_user_id).to be_nil
    end

    it 'keeps but detaches the previous Slack record when remote revocation is unavailable' do
      member = create(:member, email: 'current@example.com')
      previous_user = SlackUser.create!(
        member: member,
        slack_email: 'previous@example.com',
        slack_id: 'U_PREVIOUS'
      )
      member.set(slack_previous_user_id: previous_user.id)
      allow(Service::SlackConnector).to receive(:admin_client)
        .with('users.admin.setInactive')
        .and_return(nil)
      allow(described_class).to receive(:lookup_slack_user).with(member.email).and_return(nil)
      allow(Service::SlackConnector).to receive(:invite_to_slack).and_return(ok: true)
      allow(Service::SlackConnector).to receive(:new_signup_invite_mode).and_return('full_member')

      result = described_class.invite_slack(member)

      expect(result[:status]).to eq(:invited)
      expect(SlackUser.find(previous_user.id)).to have_attributes(
        member_id: nil,
        slack_id: 'U_PREVIOUS'
      )
      expect(previous_user.reload.invalidated_at).to be_present
      expect(previous_user.invalidation_reason).to match(/revocation unavailable/i)
    end

    it 'records API confirmation and the selected invitation mode' do
      member = create(:member)
      allow(Service::SlackConnector).to receive(:invite_to_slack).and_return(ok: true)
      allow(Service::SlackConnector).to receive(:new_signup_invite_mode)
        .and_return('single_channel_guest')

      described_class.invite_slack(member)

      member.reload
      expect(member.slack_invite_source).to eq('api')
      expect(member.slack_invite_mode).to eq('single_channel_guest')
      expect(member.slack_invite_confirmed_at).to be_present
    end

    it 'marks manual invitation required when no admin token is available' do
      member = create(:member)
      allow(ENV).to receive(:[]).with('SLACK_INVITES_ENABLED').and_return('true')
      allow(ENV).to receive(:[]).with('SLACK_ADMIN_TOKEN').and_return(nil)
      allow(Service::SlackConnector).to receive(:invite_to_slack)
        .and_raise(Error::NotAllowed.new('token missing'))

      described_class.invite_slack(member)

      expect(member.reload.slack_manual_action_required).to eq('invite')
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(
          event_type: 'slack_manual_invite_required',
          slack_channel: Service::SlackConnector.admin_channel
        )
      )
    end

    it 'blocks revoked and inactive members' do
      %w[revoked inactive].each do |status|
        member = create(:member, status: status)
        expect do
          described_class.invite_slack(member, raise_errors: true)
        end.to raise_error(Error::NotAllowed, /revoked or inactive/)
      end
    end
  end

  describe '.provision_google' do
    it 'confirms both permissions and does not duplicate existing access' do
      member = active_member_with_card
      allow(ENV).to receive(:[]).with('GDRIVE_INVITES_ENABLED').and_return('true')
      allow(ENV).to receive(:[]).with('RESOURCES_FOLDER').and_return('resources')
      allow(ENV).to receive(:[]).with('GOOGLE_TRANSFER_SHARE').and_return('transfer')

      existing_writer = double(
        email_address: member.email,
        role: 'writer',
        id: 'permission-1'
      )
      created_reader = double(
        email_address: member.email,
        role: 'reader',
        id: 'permission-2'
      )
      resources_permissions = []
      drive = double
      allow(Service::GoogleDrive).to receive(:load_gdrive).and_return(drive)
      allow(drive).to receive(:list_permissions)
        .with('resources', anything)
        .and_return(double(permissions: resources_permissions, next_page_token: nil))
      allow(drive).to receive(:list_permissions)
        .with('transfer', anything)
        .and_return(double(permissions: [existing_writer], next_page_token: nil))
      allow(drive).to receive(:create_permission) do |folder_id, _permission|
        resources_permissions << created_reader if folder_id == 'resources'
      end

      result = described_class.provision_google(member, raise_errors: true)

      expect(result[:resources][:status]).to eq(:created)
      expect(result[:transfer][:status]).to eq(:confirmed)
      expect(drive).to have_received(:create_permission).once
      member.reload
      expect(member.google_resources_access_confirmed_at).to be_present
      expect(member.google_transfer_access_confirmed_at).to be_present

      member.set(
        google_resources_access_confirmed_at: 3.weeks.ago,
        google_transfer_access_confirmed_at: 3.weeks.ago
      )
      described_class.provision_google(member, raise_errors: true)
      expect(drive).to have_received(:create_permission).once
      member.reload
      expect(member.google_resources_access_confirmed_at).to be > 1.day.ago
      expect(member.google_transfer_access_confirmed_at).to be > 1.day.ago
    end

    it 'revalidates and repairs removed or downgraded permissions after prior confirmation' do
      member = active_member_with_card
      previous_confirmation = 1.day.ago
      member.set(
        google_resources_access_confirmed_at: previous_confirmation,
        google_transfer_access_confirmed_at: previous_confirmation
      )
      allow(ENV).to receive(:[]).with('GDRIVE_INVITES_ENABLED').and_return('true')
      allow(ENV).to receive(:[]).with('RESOURCES_FOLDER').and_return('resources')
      allow(ENV).to receive(:[]).with('GOOGLE_TRANSFER_SHARE').and_return('transfer')
      downgraded_permission = double(
        email_address: member.email,
        role: 'reader',
        id: 'permission-1'
      )
      drive = double
      allow(Service::GoogleDrive).to receive(:load_gdrive).and_return(drive)
      allow(drive).to receive(:list_permissions)
        .with('resources', anything)
        .and_return(double(permissions: [], next_page_token: nil))
      allow(drive).to receive(:list_permissions)
        .with('transfer', anything)
        .and_return(double(permissions: [downgraded_permission], next_page_token: nil))
      allow(drive).to receive(:create_permission)
      allow(drive).to receive(:update_permission)

      described_class.provision_google(member, raise_errors: true)

      expect(drive).to have_received(:create_permission).with('resources', anything)
      expect(drive).to have_received(:update_permission).with(
        'transfer',
        'permission-1',
        anything
      )
      expect(member.reload.google_resources_access_confirmed_at).to be > previous_confirmation
      expect(member.google_transfer_access_confirmed_at).to be > previous_confirmation
    end

    it 'follows Drive permission pagination before deciding access is absent' do
      member = active_member_with_card
      allow(ENV).to receive(:[]).with('GDRIVE_INVITES_ENABLED').and_return('true')
      allow(ENV).to receive(:[]).with('RESOURCES_FOLDER').and_return('resources')
      allow(ENV).to receive(:[]).with('GOOGLE_TRANSFER_SHARE').and_return('transfer')
      permission = double(email_address: member.email, role: 'writer', id: 'permission-1')
      drive = double
      allow(Service::GoogleDrive).to receive(:load_gdrive).and_return(drive)
      allow(drive).to receive(:list_permissions) do |folder_id, options|
        if options[:page_token] == 'page-2'
          double(permissions: [permission], next_page_token: nil)
        elsif folder_id == 'resources'
          double(permissions: [], next_page_token: 'page-2')
        else
          double(permissions: [permission], next_page_token: nil)
        end
      end
      expect(drive).not_to receive(:create_permission)

      result = described_class.provision_google(member, raise_errors: true)

      expect(result[:resources][:status]).to eq(:confirmed)
      expect(drive).to have_received(:list_permissions).with(
        'resources',
        hash_including(page_token: 'page-2')
      )
    end

    it 'revokes the previous email before granting permissions to the current email' do
      member = active_member_with_card
      previous_email = 'previous@example.com'
      member.set(google_previous_email: previous_email)
      allow(ENV).to receive(:[]).with('GDRIVE_INVITES_ENABLED').and_return('true')
      allow(ENV).to receive(:[]).with('RESOURCES_FOLDER').and_return('resources')
      allow(ENV).to receive(:[]).with('GOOGLE_TRANSFER_SHARE').and_return('transfer')
      permissions = {
        'resources' => [double(email_address: previous_email, role: 'reader', id: 'old-resources')],
        'transfer' => [double(email_address: previous_email, role: 'writer', id: 'old-transfer')]
      }
      drive = double
      allow(Service::GoogleDrive).to receive(:load_gdrive).and_return(drive)
      allow(drive).to receive(:list_permissions) do |folder_id, _options|
        double(permissions: permissions.fetch(folder_id), next_page_token: nil)
      end
      allow(drive).to receive(:delete_permission) do |folder_id, permission_id|
        permissions.fetch(folder_id).reject! { |permission| permission.id == permission_id }
      end
      allow(drive).to receive(:create_permission)

      described_class.provision_google(member, raise_errors: true)

      expect(drive).to have_received(:delete_permission).with('resources', 'old-resources').ordered
      expect(drive).to have_received(:delete_permission).with('transfer', 'old-transfer').ordered
      expect(drive).to have_received(:create_permission).with('resources', anything).ordered
      expect(drive).to have_received(:create_permission).with('transfer', anything).ordered
      member.reload
      expect(member.google_previous_email).to be_nil
      expect(member.google_resources_access_confirmed_at).to be_present
      expect(member.google_transfer_access_confirmed_at).to be_present
    end

    it 'retains the previous email and does not grant new access when revocation fails' do
      member = active_member_with_card
      previous_email = 'previous@example.com'
      member.set(google_previous_email: previous_email)
      allow(ENV).to receive(:[]).with('GDRIVE_INVITES_ENABLED').and_return('true')
      allow(ENV).to receive(:[]).with('RESOURCES_FOLDER').and_return('resources')
      allow(ENV).to receive(:[]).with('GOOGLE_TRANSFER_SHARE').and_return('transfer')
      old_permission = double(email_address: previous_email, role: 'reader', id: 'old-resources')
      drive = double
      allow(Service::GoogleDrive).to receive(:load_gdrive).and_return(drive)
      allow(drive).to receive(:list_permissions)
        .and_return(double(permissions: [old_permission], next_page_token: nil))
      allow(drive).to receive(:delete_permission)
        .and_raise(StandardError.new('Drive unavailable'))
      expect(drive).not_to receive(:create_permission)

      expect do
        described_class.provision_google(member, raise_errors: true)
      end.to raise_error(StandardError, 'Drive unavailable')

      expect(member.reload.google_previous_email).to eq(previous_email)
      expect(member.google_resources_access_confirmed_at).to be_nil
      expect(member.google_transfer_access_confirmed_at).to be_nil
    end

    it 'strictly rejects members who are not activated' do
      member = create(:member, expirationTime: 1.month.from_now.to_i * 1000)

      expect do
        described_class.provision_google(member, raise_errors: true)
      end.to raise_error(Error::NotAllowed, /usable fob/)
    end
  end

  describe '.reconcile_all!' do
    it 'revalidates Drive access when a local confirmation is at least two weeks old' do
      member = active_member_with_card
      member.set(
        provisioning_initialized_at: 1.day.ago,
        provisioning_email: member.email,
        google_resources_access_confirmed_at: 3.weeks.ago,
        google_transfer_access_confirmed_at: 1.day.ago
      )
      allow(ENV).to receive(:[]).with('GDRIVE_INVITES_ENABLED').and_return('true')
      allow(described_class).to receive(:slack_users_by_email).and_return({})
      allow(described_class).to receive(:reconcile_slack_member)
      allow(described_class).to receive(:provision_google)

      described_class.reconcile_all!

      expect(described_class).to have_received(:provision_google).with(member)
    end

    it 'skips Drive revalidation when both confirmations are less than two weeks old' do
      member = active_member_with_card
      member.set(
        provisioning_initialized_at: 1.day.ago,
        provisioning_email: member.email,
        google_resources_access_confirmed_at: 1.day.ago,
        google_transfer_access_confirmed_at: 13.days.ago
      )
      allow(ENV).to receive(:[]).with('GDRIVE_INVITES_ENABLED').and_return('true')
      allow(described_class).to receive(:slack_users_by_email).and_return({})
      allow(described_class).to receive(:reconcile_slack_member)
      expect(described_class).not_to receive(:provision_google)

      described_class.reconcile_all!
    end
  end

  describe 'Slack reconciliation and promotion' do
    it 'leaves an accepted guest unchanged until activation' do
      member = create(:member, expirationTime: 1.month.from_now.to_i * 1000)
      user = {
        'id' => 'U123',
        'name' => 'member',
        'profile' => { 'email' => member.email, 'real_name' => member.fullname },
        'is_ultra_restricted' => true
      }
      expect(Service::SlackConnector).not_to receive(:promote_to_regular)

      result = described_class.reconcile_slack_member(member, user)

      expect(result[:status]).to eq(:guest)
      expect(member.reload.slack_joined_at).to be_present
    end

    it 'marks manual promotion required when the legacy promotion call fails' do
      member = active_member_with_card
      user = {
        'id' => 'U123',
        'name' => 'member',
        'profile' => { 'email' => member.email, 'real_name' => member.fullname },
        'is_ultra_restricted' => true
      }
      allow(Service::SlackConnector).to receive(:promote_to_regular)
        .and_raise(StandardError.new('legacy endpoint failed'))

      result = described_class.reconcile_slack_member(member, user)

      expect(result[:status]).to eq(:manual_promotion_required)
      expect(member.reload.slack_manual_action_required).to eq('promotion')
    end
  end

  describe '.backfill!' do
    it 'records local and remote confirmation without changing remote access' do
      member = create(:member)
      SlackUser.create!(
        member: member,
        slack_email: member.email,
        slack_id: 'U123',
        name: 'member'
      )
      allow(described_class).to receive(:slack_users_by_email).and_return({})
      allow(described_class).to receive(:google_permission_emails)
        .and_return(Set.new([member.email]))
      expect(Service::SlackConnector).not_to receive(:invite_to_slack)
      expect(Service::SlackConnector).not_to receive(:promote_to_regular)

      result = described_class.backfill!

      expect(result[:slack_invited]).to eq(1)
      expect(member.reload.slack_invite_source).to eq('slack_user_record')
      expect(member.google_resources_access_confirmed_at).to be_present
      expect(member.google_transfer_access_confirmed_at).to be_present
    end
  end

  describe '.provisioning_status' do
    it 'keeps unreconciled legacy members unknown' do
      member = create(:member)
      expect(described_class.provisioning_status(member).dig(:slack, :status)).to eq('unknown')
    end

    it 'invalidates current-email confirmation after an email change' do
      member = create(:member)
      member.set(
        provisioning_initialized_at: Time.current,
        provisioning_email: member.email,
        slack_invite_confirmed_at: Time.current,
        slack_invite_source: 'api',
        google_resources_access_confirmed_at: Time.current
      )

      member.update!(email: 'changed@example.com')

      member.reload
      expect(member.provisioning_email).to eq('changed@example.com')
      expect(member.slack_invite_confirmed_at).to be_nil
      expect(member.slack_manual_action_required).to eq('invite')
      expect(member.google_resources_access_confirmed_at).to be_nil
    end
  end
end
