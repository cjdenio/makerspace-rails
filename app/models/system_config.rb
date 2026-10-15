class SystemConfig
  include Mongoid::Document
  include Mongoid::Timestamps

  store_in collection: "system_configs"

  field :key,         type: String
  field :value,       type: String  # stored as string, cast on read
  field :last_run_at, type: Time
  field :last_run_status, type: String  # "success" | "failure"

  index({ key: 1 }, { unique: true })

  SLACK_SYNC_ENABLED = "slack_sync_enabled"
  SLACK_PROFILE_SYNC_ENABLED = "slack_profile_sync_enabled"
  SIGNUP_LOCKOUT_ENABLED = "signup_lockout_enabled"

  # Heroku Scheduler has no native monthly cadence, so these jobs run daily
  # via a rake task that only does real work on the configured day of month.
  CHANNEL_CACHE_REFRESH_DAY = "channel_cache_refresh_day"
  CARD_EXPIRATION_CHECK_DAY = "card_expiration_check_day"
  GARBAGE_COLLECT_DAY = "garbage_collect_day"

  JOB_KEYS = {
    "slack_sync"      => "slack:sync_users",
    "slack_profile_sync" => "slack:sync_profiles",
    "slack_channel_cache" => "slack:refresh_public_channel_cache",
    "member_review"   => "member_review",
    "invoice_review"  => "invoice_review",
    "garbage_collect" => "gc",
    "db_backup"       => "backup",
    "card_expiration_check" => "card_expiration_check",
    "reservation_canvas_rebuild" => "reservations:rebuild_slack_canvases",
    "member_provisioning_reconciliation" => "member_provisioning_reconciliation",
    "volunteer_event_reminder" => "volunteer_event_reminder",
    "membership_expiration_notice" => "membership_expiration_notice",
    "checkout_request_reminder" => "checkout_request_reminder",
    "checkout_request_digest" => "checkout_request_digest"
  }.freeze

  def self.get(key)
    find_by(key: key)&.value
  end

  # A saved blank value explicitly disables publication; only an absent override
  # uses the environment. Never substitute a default Slack channel.
  def self.slack_tickets_channel
    (get('slack_channel_tickets') || ENV['SLACK_TICKETS_CHANNEL']).to_s.strip
  end

  def self.set(key, value)
    record = find_or_initialize_by(key: key)
    record.value = value.to_s
    record.save!
    record
  end

  # Heroku Scheduler has no monthly cadence -- a "monthly" job is scheduled
  # to run daily and calls this to no-op except on its configured day.
  def self.scheduled_day_matches?(key, default: 1)
    configured_day = get(key).presence&.to_i || default
    Date.current.day == configured_day
  end

  def self.enabled?(key)
    get(key).to_s.downcase == "true"
  end

  def self.record_run(job_key, success:)
    record = find_or_initialize_by(key: "job_status_#{job_key}")
    record.last_run_at     = Time.now
    record.last_run_status = success ? "success" : "failure"
    record.save!
  end

  def self.job_status(job_key)
    record = find_by(key: "job_status_#{job_key}")
    return nil unless record
    {
      last_run_at:     record.last_run_at,
      last_run_status: record.last_run_status
    }
  end
end
