class MailtrapEvent
  include Mongoid::Document
  include Mongoid::Attributes::Dynamic
  include Mongoid::Timestamps::Created

  store_in collection: "mailtrap"

  field :member_id, type: BSON::ObjectId
  field :email, type: String
  field :status, type: String
  field :occurred_at, type: Time
  field :event, type: String
  field :event_id, type: String
  field :message_id, type: String
  field :response, type: String
  field :sending_stream, type: String
  field :sending_domain_name, type: String
  field :timestamp, type: Integer
  field :raw_payload, type: Hash

  # Links to MailtrapMessage for subject/mailer context captured at send time
  field :mailtrap_message_id, type: BSON::ObjectId

  index({ member_id:           1 })
  index({ event_id:            1 }, { unique: true, sparse: true })
  index({ message_id:          1 })
  index({ occurred_at:         1 })
  index({ mailtrap_message_id: 1 }, { sparse: true })
end
