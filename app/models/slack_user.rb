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

  validates :slack_id, uniqueness: true, allow_nil: true

  index({ slack_id: 1 }, {
    unique: true,
    partial_filter_expression: { slack_id: { '$type' => 'string' } }
  })

  attr_readonly *fields.keys
end
