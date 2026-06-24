module Service
  module MemberAccess
    # Revoke Google Drive and Slack access for a member.
    # Safe to call from rake tasks, subscribers, or controllers.
    def self.revoke(member)
      results = {}
      results[:gdrive_resources]      = revoke_gdrive_folder(member.email, ENV['RESOURCES_FOLDER'],      'Resources (reader)')
      results[:gdrive_transfer_share] = revoke_gdrive_folder(member.email, ENV['GOOGLE_TRANSFER_SHARE'], 'Transfer Share (writer)')
      results[:slack]                 = revoke_slack_access(member.email)
      results
    end

    # ── Google Drive ──────────────────────────────────────────────────────────

    def self.revoke_gdrive_folder(email, folder_id, label)
      return { status: :skipped, reason: "#{label} folder env var not configured" } if folder_id.blank?
      return { status: :skipped, reason: 'GDRIVE_INVITES_ENABLED is not true' } unless ENV['GDRIVE_INVITES_ENABLED'] == 'true'

      begin
        drive       = Service::GoogleDrive.load_gdrive
        permissions = drive.list_permissions(folder_id, fields: 'permissions(id,emailAddress,role)')
        perm        = permissions.permissions.find { |p| p.email_address&.downcase == email.downcase }

        if perm
          drive.delete_permission(folder_id, perm.id)
          { status: :ok, message: "Removed #{perm.role} permission from #{label}" }
        else
          { status: :not_found, message: "No permission found for #{email} on #{label}" }
        end
      rescue => e
        { status: :error, message: e.message }
      end
    end

    # ── Slack ─────────────────────────────────────────────────────────────────

    def self.revoke_slack_access(email)
      return { status: :skipped, reason: 'SLACK_ADMIN_TOKEN not configured' } unless ENV['SLACK_ADMIN_TOKEN'].present?

      begin
        client = Slack::Web::Client.new(token: ENV['SLACK_ADMIN_TOKEN'])
        user   = client.users_lookupByEmail(email: email)
        client.users_admin_setInactive(user: user.user.id)
        { status: :ok, message: "Deactivated Slack user for #{email}" }
      rescue Slack::Web::Api::Errors::UsersNotFound
        { status: :not_found, message: "No Slack user found for #{email}" }
      rescue => e
        { status: :error, message: e.message }
      end
    end
  end
end
