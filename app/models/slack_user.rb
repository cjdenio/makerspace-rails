class SlackUser
  include Mongoid::Document
  include SanitizesUserInput
  belongs_to :member, optional: true

  field :slack_email, type: String
  field :slack_id, type: String
  field :name, type: String
  field :real_name, type: String
  field :invalidated_at, type: Time
  field :invalidation_reason, type: String
  field :last_slack_event_ts, type: Float
  field :welcomed_at, type: Time

  default_scope -> { where(invalidated_at: nil) }

  validates :member_id, :slack_email, uniqueness: {
    conditions: -> { where(invalidated_at: nil) }
  }, allow_nil: true
  validates :slack_id, uniqueness: true, allow_nil: true

  index({ member_id: 1 }, {
    unique: true,
    partial_filter_expression: {
      member_id: { '$type' => 'objectId' },
      invalidated_at: nil
    }
  })
  index({ slack_email: 1 }, {
    unique: true,
    partial_filter_expression: {
      slack_email: { '$type' => 'string' },
      invalidated_at: nil
    }
  })
  index({ slack_id: 1 }, {
    unique: true,
    partial_filter_expression: { slack_id: { '$type' => 'string' } }
  })

  attr_readonly *fields.keys

  # Explicit ID lookups are used by administrative reconciliation workflows
  # that need access to historical identities. Ordinary relationship and
  # identity queries retain the active-only default scope above.
  def self.find(*ids)
    unscoped.find(*ids)
  end
end
