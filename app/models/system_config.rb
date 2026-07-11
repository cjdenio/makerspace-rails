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

  JOB_KEYS = {
    "slack_sync"      => "slack:sync_users",
    "slack_profile_sync" => "slack:sync_profiles",
    "member_review"   => "member_review",
    "invoice_review"  => "invoice_review",
    "garbage_collect" => "gc",
    "db_backup"       => "db:backup"
  }.freeze

  def self.get(key)
    find_by(key: key)&.value
  end

  def self.set(key, value)
    record = find_or_initialize_by(key: key)
    record.value = value.to_s
    record.save!
    record
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
