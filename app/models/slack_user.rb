class SlackUser
  include Mongoid::Document
  include SanitizesUserInput
  belongs_to :member, optional: true

  field :slack_email, type: String
  field :slack_id, type: String
  field :name, type: String
  field :real_name, type: String

  attr_readonly *fields.keys
end