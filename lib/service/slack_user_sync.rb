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

      member = slack_email.present? ? Member.find_by(email: slack_email) : nil

      unless member
        ::Service::SlackConnector.send_slack_message(
          "⚠ Slack user *#{real_name.presence || name}* (`#{slack_id}`)" \
          " attempted a command but has no linked Member account." \
          "#{slack_email.present? ? " Email on file: #{slack_email}" : ' No email on Slack profile.'}",
          ::Service::SlackConnector.logs_channel
        )
        return nil
      end

      slack_user_attributes = sanitized_slack_user_attributes(
        slack_email: slack_email,
        name: name,
        real_name: real_name
      )

      existing = SlackUser.find_by(slack_id: slack_id)
      if existing
        existing.set(slack_user_attributes)
      else
        slack_user = SlackUser.create!(
          slack_user_attributes.merge(
            slack_id: slack_id,
            member: member
          )
        )
        ::Service::SlackProfileSync.sync_one(member)
      end

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
        Honeybadger.notify('Slack user sync failed', context: { reason: 'no Slack API token configured' }) if defined?(Honeybadger)
        raise msg
      end

      client = ::Service::SlackConnector.client

      created_count = 0
      updated_count = 0
      skipped_count = 0
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

          member = Member.find_by(email: slack_email)

          unless member
            unmatched << { slack_id: slack_id, name: real_name.presence || name, email: slack_email }
            next
          end

          slack_user_attributes = sanitized_slack_user_attributes(
            slack_email: slack_email,
            name: name,
            real_name: real_name
          )
          existing = SlackUser.find_by(slack_id: slack_id)

          if existing
            existing.set(slack_user_attributes)
            puts "[Slack Sync] UPDATED #{real_name} (#{slack_id}) -> Member #{member.fullname}"
            updated_count += 1
          else
            slack_user = SlackUser.create!(
              slack_user_attributes.merge(
                slack_id: slack_id,
                member: member
              )
            )
            ::Service::SlackProfileSync.sync_one(member)
            puts "[Slack Sync] CREATED #{real_name} (#{slack_id}) -> Member #{member.fullname}"
            created_count += 1
          end
        end

      rescue Slack::Web::Api::Errors::SlackError => e
        puts "[Slack Sync] ERROR: #{e.message}"
        Honeybadger.notify('Slack user sync failed', context: { error: e.message }) if defined?(Honeybadger)
        raise e
      rescue => e
        puts "[Slack Sync] ERROR: #{e.message}"
        Honeybadger.notify('Slack user sync failed', context: { error: e.message }) if defined?(Honeybadger)
        raise e
      end

      puts "[Slack Sync] ✅ Complete — Created: #{created_count}, Updated: #{updated_count}, Skipped: #{skipped_count}, Unmatched: #{unmatched.size}"

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

      { created: created_count, updated: updated_count, skipped: skipped_count, unmatched: unmatched.size }
    end
  end
end
