module Service
  module SlackUserSync

    def self.sync_single(slack_id)
      unless ::Service::SlackConnector.api_token_present?
        ::Service::SlackConnector.send_slack_message(
          "⚠ Slack single-user sync failed: neither SLACK_BOT_TOKEN nor SLACK_ADMIN_TOKEN is set.",
          ::Service::SlackConnector.logs_channel
        )
        return nil
      end

      client = ::Service::SlackConnector.client

      begin
        response = client.users_info(user: slack_id)
      rescue Slack::Web::Api::Errors::SlackError => e
        ::Service::SlackConnector.send_slack_message(
          "⚠ Slack single-user sync failed for #{slack_id}: #{e.message}",
          ::Service::SlackConnector.logs_channel
        )
        return nil
      end

      slack_user_data = response['user']
      return nil unless slack_user_data

      slack_email = slack_user_data.dig('profile', 'email').to_s.strip.downcase
      name        = slack_user_data['name'].to_s.strip
      real_name   = slack_user_data.dig('profile', 'real_name').to_s.strip

      existing = SlackUser.unscoped.where(slack_id: slack_id).first
      return nil if existing && quarantined_identity?(existing)

      member = resolve_member(
        existing: existing,
        slack_email: slack_email,
        slack_id: slack_id,
        display_name: real_name.presence || name,
        source: 'single-user sync'
      )

      unless member
        ::Service::SlackConnector.send_slack_message(
          "⚠ Slack user *#{real_name.presence || name}* (`#{slack_id}`)" \
          " attempted a command but has no linked Member account." \
          "#{slack_email.present? ? " Email on file: #{slack_email}" : ' No email on Slack profile.'}",
          ::Service::SlackConnector.logs_channel
        )
        return nil
      end

      unless member.active_membership_status?
        ::Service::SlackConnector.send_slack_message(
          "⚠ Slack user *#{real_name.presence || name}* (`#{slack_id}`) matches Member " \
          "#{member.fullname}, who is not in good standing (status: #{member.status}). Skipping sync.",
          ::Service::SlackConnector.logs_channel
        )
        return nil
      end

      slack_user_attributes = sanitized_slack_user_attributes(
        slack_email: slack_email,
        name: name,
        real_name: real_name
      )

      if existing
        conflict = active_identity_conflict(member, excluding: existing)
        if conflict
          report_identity_conflict(
            member, slack_id, conflict, 'single-user sync',
            slack_name: real_name.presence || name, slack_email: slack_email
          )
          return nil
        end

        persistence_attributes = safe_persistence_attributes(existing, slack_user_attributes)
        SlackUser.collection.find(_id: existing.id).update_one(
          '$set' => persistence_attributes.merge(member_id: member.id),
          '$unset' => { invalidated_at: '', invalidation_reason: '' }
        )
      else
        conflict = active_identity_conflict(member)
        if conflict
          report_identity_conflict(
            member, slack_id, conflict, 'single-user sync',
            slack_name: real_name.presence || name, slack_email: slack_email
          )
          return nil
        end

        slack_user = SlackUser.create!(
          slack_user_attributes.merge(
            slack_id: slack_id,
            member: member
          )
        )
        ::Service::SlackProfileSync.sync_one(member)
      end

      reconcile_provisioning(member, slack_user_data, slack_id: slack_id)

      member
    end

    def self.sanitized_slack_user_attributes(slack_email:, name:, real_name:)
      {
        slack_email: SlackUser.scrub_user_input(slack_email),
        name: SlackUser.scrub_user_input(name),
        real_name: SlackUser.scrub_user_input(real_name)
      }
    end

    def self.sync_all
      unless SystemConfig.enabled?(SystemConfig::SLACK_SYNC_ENABLED)
        puts '[Slack Sync] Skipping — slack_sync_enabled is not set to true in SystemConfig'
        return { skipped: true }
      end

      unless ::Service::SlackConnector.api_token_present?
        msg = '[Slack Sync] ERROR: neither SLACK_BOT_TOKEN nor SLACK_ADMIN_TOKEN is set'
        puts msg
        Service::ErrorReporter.notify('Slack user sync failed', context: { reason: 'no Slack API token configured' })
        raise msg
      end

      client = ::Service::SlackConnector.client

      created_count = 0
      updated_count = 0
      skipped_count = 0
      failed_count  = 0
      unmatched     = []

      puts '[Slack Sync] Starting Slack user sync...'

      begin
        cursor      = nil
        slack_users = []

        loop do
          response = client.users_list(limit: 200, cursor: cursor)
          raise 'Slack API returned ok=false' unless response['ok']
          slack_users.concat(response['members'])
          cursor = response.dig('response_metadata', 'next_cursor')
          break if cursor.blank?
        end

        puts "[Slack Sync] Fetched #{slack_users.size} users from Slack workspace"

        slack_users.each do |slack_user|
          next if slack_user['is_bot']
          next if slack_user['deleted']
          next if slack_user['id'] == 'USLACKBOT'

          slack_id    = slack_user['id']
          slack_email = slack_user.dig('profile', 'email').to_s.strip.downcase
          name        = slack_user['name'].to_s.strip
          real_name   = slack_user.dig('profile', 'real_name').to_s.strip

          if slack_email.blank?
            puts "[Slack Sync] SKIP #{name} (#{slack_id}) — no email on profile"
            skipped_count += 1
            next
          end

          # A failure processing one Slack user (e.g. a validation error on
          # create) must not abort the sync for the remaining users in the
          # workspace — log/report it and move on instead.
          begin
            existing = SlackUser.unscoped.where(slack_id: slack_id).first
            if existing && quarantined_identity?(existing)
              puts "[Slack Sync] SKIP #{real_name} (#{slack_id}) — identity quarantined after member email change"
              skipped_count += 1
              next
            end
            member = resolve_member(
              existing: existing,
              slack_email: slack_email,
              slack_id: slack_id,
              display_name: real_name.presence || name,
              source: 'bulk sync'
            )

            unless member
              unmatched << { slack_id: slack_id, name: real_name.presence || name, email: slack_email }
              next
            end

            unless member.active_membership_status?
              puts "[Slack Sync] SKIP #{real_name} (#{slack_id}) — Member #{member.fullname} is not in good standing (status: #{member.status})"
              skipped_count += 1
              next
            end

            slack_user_attributes = sanitized_slack_user_attributes(
              slack_email: slack_email,
              name: name,
              real_name: real_name
            )
            if existing
              conflict = active_identity_conflict(member, excluding: existing)
              if conflict
                puts "[Slack Sync] SKIP #{real_name} (#{slack_id}) — Member #{member.fullname} already has an active Slack identity"
                report_identity_conflict(
                  member, slack_id, conflict, 'bulk sync',
                  slack_name: real_name.presence || name, slack_email: slack_email
                )
                skipped_count += 1
                next
              end

              persistence_attributes = safe_persistence_attributes(existing, slack_user_attributes)
              SlackUser.collection.find(_id: existing.id).update_one(
                '$set' => persistence_attributes.merge(member_id: member.id),
                '$unset' => { invalidated_at: '', invalidation_reason: '' }
              )
              puts "[Slack Sync] UPDATED #{real_name} (#{slack_id}) -> Member #{member.fullname}"
              updated_count += 1
            else
              conflict = active_identity_conflict(member)
              if conflict
                puts "[Slack Sync] SKIP #{real_name} (#{slack_id}) — Member #{member.fullname} already has an active Slack identity"
                report_identity_conflict(
                  member, slack_id, conflict, 'bulk sync',
                  slack_name: real_name.presence || name, slack_email: slack_email
                )
                skipped_count += 1
                next
              end

              SlackUser.create!(
                slack_user_attributes.merge(
                  slack_id: slack_id,
                  member: member
                )
              )
              ::Service::SlackProfileSync.sync_one(member)
              puts "[Slack Sync] CREATED #{real_name} (#{slack_id}) -> Member #{member.fullname}"
              created_count += 1
            end

            reconcile_provisioning(member, slack_user, slack_id: slack_id)
          rescue => e
            puts "[Slack Sync] FAILED #{real_name} (#{slack_id}) — #{e.message}"
            Service::ErrorReporter.notify(e, context: { slack_id: slack_id, phase: 'bulk sync per-user' })
            failed_count += 1
          end
        end

      rescue Slack::Web::Api::Errors::SlackError => e
        puts "[Slack Sync] ERROR: #{e.message}"
        Service::ErrorReporter.notify('Slack user sync failed', context: { error: e.message })
        raise e
      rescue => e
        puts "[Slack Sync] ERROR: #{e.message}"
        Service::ErrorReporter.notify('Slack user sync failed', context: { error: e.message })
        raise e
      end

      puts "[Slack Sync] ✅ Complete — Created: #{created_count}, Updated: #{updated_count}, Skipped: #{skipped_count}, Failed: #{failed_count}, Unmatched: #{unmatched.size}"

      # Fix #4 — Post unmatched users to logs channel
      if unmatched.any?
        lines = ["⚠ *Slack Sync* — #{unmatched.size} Slack user#{'s' if unmatched.size != 1} have no matching Member account:"]
        unmatched.each do |u|
          lines << "• *#{u[:name]}* (`#{u[:slack_id]}`) — #{u[:email]}"
        end
        ::Service::SlackConnector.send_slack_message(
          lines.join("\n"),
          ::Service::SlackConnector.logs_channel
        )
      end

      { created: created_count, updated: updated_count, skipped: skipped_count, failed: failed_count, unmatched: unmatched.size }
    end

    # Reassigning an identity is a deliberate, permanent admin decision, same
    # as a member_email_changed tombstone -- unlike e.g. 'slack_user_deleted',
    # neither should ever silently auto-reactivate on a later sync.
    MANUAL_REASSIGNMENT_REASON = 'manually_reassigned_by_admin'.freeze

    def self.quarantined_identity?(record)
      record.invalidated_at.present? &&
        (record.invalidation_reason.to_s.start_with?('member_email_changed') ||
         record.invalidation_reason.to_s.start_with?(MANUAL_REASSIGNMENT_REASON))
    end

    # Scan for Slack identity conflicts an admin needs to resolve. Combines
    # two sources:
    #  - a live re-derivation against Slack's current directory (the same
    #    matching sync_all performs) -- always fresh, no bookkeeping needed
    #    for conflicts it can find this way.
    #  - persisted SlackIdentityConflict records not yet resolved -- covers
    #    conflicts reported by a one-off reconciliation (e.g. member
    #    provisioning, see #ensure_slack_user_record) whose rejected identity
    #    may no longer independently reproduce via a live directory scan
    #    (deactivated, email changed, etc.) even though nothing ever actually
    #    resolved it for the member.
    def self.detect_conflicts
      conflicts = live_conflicts
      found_slack_ids = conflicts.map { |c| c[:slack_id] }

      SlackIdentityConflict.unresolved.each do |persisted|
        next if found_slack_ids.include?(persisted.slack_id)

        member = Member.find_by(id: persisted.member_id)
        next unless member

        conflicts << {
          slack_id: persisted.slack_id,
          slack_name: persisted.slack_name,
          slack_email: persisted.slack_email,
          member_id: member.id.to_s,
          member_name: member.fullname,
          conflicting_slack_id: persisted.conflicting_slack_id,
          conflicting_slack_name: persisted.conflicting_slack_name,
          conflicting_slack_email: persisted.conflicting_slack_email
        }
      end

      conflicts
    end

    def self.live_conflicts
      return [] unless ::Service::SlackConnector.api_token_present?

      client = ::Service::SlackConnector.client
      conflicts = []
      cursor = nil

      loop do
        response = client.users_list(limit: 200, cursor: cursor)
        raise 'Slack API returned ok=false' unless response['ok']

        response['members'].each do |slack_user|
          next if slack_user['is_bot'] || slack_user['deleted'] || slack_user['id'] == 'USLACKBOT'

          slack_id    = slack_user['id']
          slack_email = slack_user.dig('profile', 'email').to_s.strip.downcase
          name        = slack_user['name'].to_s.strip
          real_name   = slack_user.dig('profile', 'real_name').to_s.strip
          next if slack_email.blank?

          existing = SlackUser.unscoped.where(slack_id: slack_id).first
          next if existing && quarantined_identity?(existing)

          member = resolve_member(
            existing: existing,
            slack_email: slack_email,
            slack_id: slack_id,
            display_name: real_name.presence || name,
            source: 'conflict scan'
          )
          next unless member
          next unless member.active_membership_status?

          conflict = existing ? active_identity_conflict(member, excluding: existing) : active_identity_conflict(member)
          next unless conflict

          conflicts << {
            slack_id: slack_id,
            slack_name: real_name.presence || name,
            slack_email: slack_email,
            member_id: member.id.to_s,
            member_name: member.fullname,
            conflicting_slack_id: conflict.slack_id,
            conflicting_slack_name: conflict.real_name.presence || conflict.name,
            conflicting_slack_email: conflict.slack_email
          }
        end

        cursor = response.dig('response_metadata', 'next_cursor').to_s
        break if cursor.blank?
      end

      conflicts
    end
    private_class_method :live_conflicts

    # Admin-driven resolution: unlink whichever other active identity the
    # member currently holds, then link the chosen slack_id via the normal
    # sync_single path (which now safely re-checks for a conflict itself).
    def self.reassign_identity(slack_id:, member_id:, actor: nil)
      slack_id = slack_id.to_s.strip
      raise Error::UnprocessableEntity.new('slack_id is required') if slack_id.blank?

      member = Member.find(member_id)
      raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: member_id }) if member.nil?

      previous = SlackUser.where(member_id: member.id, :slack_id.ne => slack_id).first

      if previous
        SlackUser.collection.find(_id: previous.id).update_one(
          '$unset' => { member_id: '' },
          '$set' => {
            invalidated_at: Time.current,
            invalidation_reason: MANUAL_REASSIGNMENT_REASON
          }
        )
        ::Service::AuditLogger.log(
          log_type: 'member',
          event_type: 'slack_identity_manually_reassigned',
          resource_type: 'Member',
          resource_id: member.id,
          subject: member,
          actor: actor,
          message_details: "Admin unlinked Slack identity #{previous.slack_id} from #{member.fullname} " \
            "in favor of #{slack_id}",
          slack_channel: ::Service::SlackConnector.logs_channel
        )
      end

      result = sync_single(slack_id)
      raise Error::UnprocessableEntity.new(
        "Could not link #{slack_id} to #{member.fullname} -- check Slack API connectivity and logs"
      ) unless result == member

      resolve_persisted_conflict(slack_id)
      member
    end

    # Admin-driven resolution: the member keeps their currently-linked
    # identity, and the conflicting slack_id is permanently quarantined so it
    # stops being offered or re-flagged -- without needing anything done in
    # Slack itself.
    def self.dismiss_conflict(slack_id:, member_id:, slack_email: nil, slack_name: nil, actor: nil)
      slack_id = slack_id.to_s.strip
      raise Error::UnprocessableEntity.new('slack_id is required') if slack_id.blank?

      member = Member.find(member_id)
      raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: member_id }) if member.nil?

      existing = SlackUser.unscoped.where(slack_id: slack_id).first
      if existing
        SlackUser.collection.find(_id: existing.id).update_one(
          '$unset' => { member_id: '' },
          '$set' => {
            invalidated_at: Time.current,
            invalidation_reason: MANUAL_REASSIGNMENT_REASON
          }
        )
      else
        attributes = sanitized_slack_user_attributes(
          slack_email: slack_email.to_s,
          name: slack_name.to_s,
          real_name: slack_name.to_s
        )
        SlackUser.create!(
          attributes.merge(
            slack_id: slack_id,
            invalidated_at: Time.current,
            invalidation_reason: MANUAL_REASSIGNMENT_REASON
          )
        )
      end

      ::Service::AuditLogger.log(
        log_type: 'member',
        event_type: 'slack_identity_conflict_dismissed',
        resource_type: 'Member',
        resource_id: member.id,
        subject: member,
        actor: actor,
        message_details: "Admin dismissed Slack identity #{slack_id} as a duplicate for #{member.fullname}; " \
          "it will not be offered or reconciled again.",
        slack_channel: ::Service::SlackConnector.logs_channel
      )

      resolve_persisted_conflict(slack_id)
      member
    end

    def self.resolve_member(existing:, slack_email:, slack_id:, display_name:, source:)
      linked_member = existing&.member
      if linked_member
        if slack_email.present? && normalize_email(linked_member.email) != slack_email
          if normalize_email(existing.slack_email) != slack_email
            report_email_mismatch(linked_member, slack_email, slack_id, display_name, source)
          end
        end
        return linked_member
      end

      Member.find_by(email: slack_email) if slack_email.present?
    end

    def self.report_email_mismatch(member, slack_email, slack_id, display_name, source)
      Service::AuditLogger.log(
        log_type: 'member',
        event_type: 'slack_email_mismatch',
        resource_type: 'Member',
        resource_id: member.id,
        subject: member,
        field_changes: {
          'slack_email' => [normalize_email(member.email), slack_email]
        },
        message_details: "Slack #{source} found that #{display_name} (#{slack_id}) now uses #{slack_email}, " \
          "which does not match the linked Member email. The established Member link was preserved; " \
          "an admin must reconcile the mismatch.",
        slack_channel: Service::SlackConnector.logs_channel
      )
    end

    # excluding is omitted when checking ahead of creating a brand new
    # SlackUser (there's no existing record yet to exclude from the check).
    def self.active_identity_conflict(member, excluding: nil)
      scope = SlackUser.where(member_id: member.id)
      scope = scope.where(:id.ne => excluding.id) if excluding
      scope.first
    end

    def self.report_identity_conflict(member, slack_id, conflict, source, slack_name: nil, slack_email: nil)
      persist_conflict(member, slack_id, conflict, source, slack_name: slack_name, slack_email: slack_email)

      Service::AuditLogger.log(
        log_type: 'member',
        event_type: 'slack_identity_conflict',
        resource_type: 'Member',
        resource_id: member.id,
        subject: member,
        message_details: "Slack #{source} could not reconcile identity #{slack_id} to Member " \
          "#{member.fullname}: that member already has a different active Slack identity " \
          "(#{conflict.slack_id}). An admin must reconcile the duplicate before this identity " \
          "can be reactivated.",
        slack_channel: Service::SlackConnector.logs_channel
      )
    end

    # Upserts by slack_id so a conflict re-reported by a later sync pass (the
    # same rejected identity, still unresolved) updates the existing record
    # rather than piling up duplicates.
    def self.persist_conflict(member, slack_id, conflict, source, slack_name:, slack_email:)
      SlackIdentityConflict.find_or_initialize_by(slack_id: slack_id).update!(
        slack_name: slack_name,
        slack_email: slack_email,
        member_id: member.id,
        conflicting_slack_id: conflict.slack_id,
        conflicting_slack_name: conflict.real_name.presence || conflict.name,
        conflicting_slack_email: conflict.slack_email,
        source: source,
        resolved_at: nil
      )
    rescue => e
      Service::ErrorReporter.notify(e, context: { slack_id: slack_id, member_id: member.id.to_s, phase: 'persist_conflict' })
    end

    def self.resolve_persisted_conflict(slack_id)
      SlackIdentityConflict.unresolved.where(slack_id: slack_id).update_all(resolved_at: Time.current)
    end

    def self.normalize_email(email)
      email.to_s.strip.downcase
    end

    def self.safe_persistence_attributes(existing, attributes)
      email = attributes[:slack_email]
      return attributes if email.blank?

      email_owner = SlackUser.where(slack_email: email, :id.ne => existing.id).first
      email_owner ? attributes.except(:slack_email) : attributes
    end

    # Sync only links the SlackUser record to a Member -- it doesn't touch
    # the Member-level provisioning tracking fields (slack_joined_at,
    # slack_full_member_at, etc.) that the admin UI's status icon reads, so a
    # bulk-synced member's icon would otherwise report "unknown" forever even
    # though the link is real (#243). Reusing reconcile_slack_member here
    # (the same call invite_slack makes for an already-confirmed member)
    # populates those fields from the live Slack user data sync already
    # fetched, with no extra API calls. promote: false because promoting a
    # guest to full member is a deliberate provisioning action, not something
    # a sync pass should trigger as a side effect.
    #
    # Rescues internally: the SlackUser link above already succeeded, so a
    # failure here is reported on its own rather than counted as a sync
    # failure for this user.
    def self.reconcile_provisioning(member, live_user, slack_id:)
      ::Service::MemberProvisioning.reconcile_slack_member(member, live_user, promote: false, lookup: false)
    rescue => e
      Service::ErrorReporter.notify(e, context: { slack_id: slack_id, member_id: member.id.to_s, phase: 'sync provisioning reconcile' })
    end

    # quarantined_identity? stays public -- MemberProvisioning#ensure_slack_user_record
    # needs it to recognize an admin-resolved identity before re-flagging it.
    private_class_method :resolve_member, :report_email_mismatch, :reconcile_provisioning,
      :normalize_email, :safe_persistence_attributes, :persist_conflict, :resolve_persisted_conflict
  end
end
