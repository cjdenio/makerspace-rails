# Deliberately separate from the board-readable general AuditLog.
class FixTicketReveal
  include Mongoid::Document
  field :ticket_id, type: FixTicketId
  field :admin_id, type: BSON::ObjectId
  field :created_at, type: Time, default: -> { Time.current }
  index({ ticket_id: 1, created_at: -1 })
end
