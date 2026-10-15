class MailtrapMessage
  include Mongoid::Document
  include Mongoid::Timestamps

  store_in collection: 'mailtrap_messages'

  # ── Identity ───────────────────────────────────────────────────────────────
  # ActionMailer Message-ID header — matches event_id/message_id in Mailtrap webhook payload.
  # Format: <uuid@domain> — stored as-is.
  field :message_id,   type: String

  # ── Email metadata ─────────────────────────────────────────────────────────
  field :subject,      type: String   # email subject line at time of send
  field :email,        type: String   # recipient address
  field :mailer_class, type: String   # e.g. "MemberMailer", "RentalMailer", "DeviseMailer"
  field :action,       type: String   # e.g. "welcome_email", "rental_request_approved"

  # ── Member link ────────────────────────────────────────────────────────────
  # Denormalized at send time. Member may change email later; this records
  # the address the email was actually sent to.
  field :member_id,    type: BSON::ObjectId

  # ── Indexes ────────────────────────────────────────────────────────────────
  index({ message_id: 1 }, { unique: true, sparse: true })
  index({ member_id:  1 })
  index({ email:      1 })
  index({ created_at: 1 })

  # ── Validations ────────────────────────────────────────────────────────────
  validates :message_id, presence: true
  validates :subject,    presence: true
  validates :email,      presence: true
end
