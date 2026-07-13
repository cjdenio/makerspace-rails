class AuditLog
  include Mongoid::Document
  include Mongoid::Timestamps

  store_in collection: 'audit_logs'

  # ── Discriminator ──────────────────────────────────────────────────────────
  # "member"  — changes to member records, invoices, rentals, etc.
  # "portal"  — changes to SystemConfig / portal settings
  field :log_type,      type: String

  # ── Event classification ───────────────────────────────────────────────────
  # Machine-readable action string. Examples:
  #   member_updated, membership_revoked, invoice_created, invoice_settled,
  #   rental_cancelled, rental_created, password_changed,
  #   portal_setting_changed
  # This list will grow as callsites are added.
  field :event_type,    type: String

  # ── Actor (who made the change) ────────────────────────────────────────────
  # Nil for system-initiated events (Lambda jobs, webhooks, IPN).
  field :actor_id,      type: BSON::ObjectId
  field :actor_name,    type: String   # denormalized at time of event

  # ── Subject (which member was affected) ────────────────────────────────────
  # Nil for portal-type logs where there is no member subject.
  # Same as actor when a member edits their own record.
  field :subject_id,    type: BSON::ObjectId
  field :subject_name,  type: String   # denormalized at time of event

  # ── Resource (which record was changed) ────────────────────────────────────
  field :resource_type, type: String   # Mongoid model class name: "Member", "Rental", "Invoice", etc.
  field :resource_id,   type: BSON::ObjectId

  # ── Change data ────────────────────────────────────────────────────────────
  # field_changes:   diff of only changed fields — { "status" => ["activeMember", "revoked"] }
  #                  Named field_changes to avoid collision with Mongoid::Changeable#changes
  # before_snapshot: full document before change (sensitive fields scrubbed)
  # after_snapshot:  full document after change  (sensitive fields scrubbed)
  field :field_changes,    type: Hash
  field :before_snapshot,  type: Hash
  field :after_snapshot,   type: Hash

  # ── Slack ──────────────────────────────────────────────────────────────────
  field :slack_channel,  type: String   # nil if Slack post was not requested
  field :slack_message,  type: String   # always generated; only posted if slack_channel present
  field :slack_posted,   type: Boolean  # nil if not attempted; true/false after attempt

  # ── Request context ────────────────────────────────────────────────────────
  field :ip_address,    type: String   # from Current.ip_address; nil for system events

  # ── Indexes ────────────────────────────────────────────────────────────────
  index({ log_type:     1 })
  index({ event_type:   1 })
  index({ actor_id:     1 })
  index({ subject_id:   1 })
  index({ resource_type: 1, resource_id: 1 })
  index({ created_at:   1 })

  # ── Validations ────────────────────────────────────────────────────────────
  validates :log_type,      presence: true
  validates :event_type,    presence: true
  validates :resource_type, presence: true
  validates :resource_id,   presence: true
  validates :slack_message, presence: true
end
