require 'time'

module Service
  class SlackProfileSync
    LAST_RUN_KEY = 'slack_profile_sync_last_run_at'.freeze

    def self.sync_one(member)
      return nil if member.nil?

      slack_user = SlackUser.find_by(member_id: member.id)
      if slack_user.nil? || slack_user.slack_id.blank?
        Rails.logger.warn("Member #{member.fullname} has no slack account, no profile sync possible!")
        return nil
      end

      unless ENV['SLACK_ADMIN_TOKEN'].present?
        Rails.logger.info('Cannot update slack profile without a SLACK_ADMIN_TOKEN')
        return nil
      end

      client = Slack::Web::Client.new(token: ENV['SLACK_ADMIN_TOKEN'])
      profile = {}
      profile[status_field] = { value: status_profile_value(member) }

      client.users_profile_set(user: slack_user.slack_id, profile: profile)
      member
    rescue Slack::Web::Api::Errors::SlackError => e
      ::Service::SlackConnector.send_slack_message(
        "⚠️ Error updating Slack profile for #{member.fullname}: #{e.message}",
        ::Service::SlackConnector.logs_channel
      )
      nil
    end

    def self.sync_all
      unless SystemConfig.enabled?(SystemConfig::SLACK_PROFILE_SYNC_ENABLED)
        puts '[Slack Profile Sync] Skipping - slack_profile_sync_enabled is not set to true in SystemConfig'
        return { skipped: true }
      end

      unless ENV['SLACK_ADMIN_TOKEN'].present?
        msg = '[Slack Profile Sync] ERROR: SLACK_ADMIN_TOKEN is not set'
        puts msg
        Honeybadger.notify('Slack profile sync failed', context: { reason: 'SLACK_ADMIN_TOKEN not set' }) if defined?(Honeybadger)
        raise msg
      end

      last_run_at = SystemConfig.get(LAST_RUN_KEY)
      last_run_at = Time.iso8601(last_run_at) if last_run_at.present? && !last_run_at.is_a?(Time)
      now = Time.current

      scope = Member.where(:expirationTime.ne => nil, :expirationTime.gt => (last_run_at || Time.at(0)).to_i * 1000)
      scope = scope.where(:expirationTime.lte => now.to_i * 1000)

      synced_count = 0
      scope.each do |member|
        next if member.nil?
        sync_one(member)
        synced_count += 1
      end

      SystemConfig.set(LAST_RUN_KEY, now.utc.iso8601)
      { synced: synced_count, last_run_at: now }
    rescue => e
      puts "[Slack Profile Sync] ERROR: #{e.message}"
      Honeybadger.notify('Slack profile sync failed', context: { error: e.message }) if defined?(Honeybadger)
      raise e
    end

    def self.status_profile_value(member)
      member.expirationTime.present? && Time.at(member.expirationTime / 1000) < Time.current ? 'Expired' : member.status
    end

    def self.status_field
      ENV['SLACK_PROFILE_STATUS'].presence || 'Xf084350PJ8K'
    end
    private_class_method :status_profile_value, :status_field
  end
end
