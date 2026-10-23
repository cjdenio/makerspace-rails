class SlackIdentityConflict
  include Mongoid::Document
  include Mongoid::Timestamps

  store_in collection: 'slack_identity_conflicts'

  # The rejected identity -- the Slack account that could not be linked.
  field :slack_id,                type: String
  field :slack_name,              type: String
  field :slack_email,             type: String

  field :member_id,               type: BSON::ObjectId

  # The other, already-linked identity it collided with.
  field :conflicting_slack_id,    type: String
  field :conflicting_slack_name,  type: String
  field :conflicting_slack_email, type: String

  # Which code path reported this: 'single-user sync', 'bulk sync', or
  # 'member_provisioning' -- see Service::SlackUserSync.report_identity_conflict.
  field :source,                  type: String

  # Set once an admin calls reassign_identity or dismiss_conflict for this
  # slack_id. Left unset (not deleted) so there's a durable record of how
  # every conflict was resolved.
  field :resolved_at,             type: Time

  validates :slack_id,  presence: true
  validates :member_id, presence: true

  scope :unresolved, -> { where(resolved_at: nil) }

  index({ slack_id: 1 })
  index({ member_id: 1 })
  index({ resolved_at: 1 })
end
