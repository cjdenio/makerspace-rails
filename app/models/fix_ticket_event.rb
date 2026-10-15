# Actor identities are internal. All output goes through FixTicketPresenter.
class FixTicketEvent
  include Mongoid::Document
  field :ticket_id, type: FixTicketId
  field :actor_id, type: BSON::ObjectId
  field :kind, type: String
  field :note, type: String
  # Private author context captured at submission; never inferred retroactively.
  field :note_role, type: String
  field :field_changes, type: Hash, default: {}
  field :recipients, type: Array, default: []
  field :unscoped_staff_notification, type: Boolean, default: false
  field :created_at, type: Time, default: -> { Time.current }
  field :delivered, type: Hash, default: {}
  field :central_enabled, type: Boolean, default: -> { SystemConfig.slack_tickets_channel.present? }
  field :delivery_attempts, type: Hash, default: {}
  field :delivery_error, type: String
  field :completed_at, type: Time
  field :revision, type: Integer
  index({ ticket_id: 1, revision: 1 }, unique: true)
  index({ completed_at: 1, created_at: 1 })
end
