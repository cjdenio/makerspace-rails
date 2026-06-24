class Shop
  include Mongoid::Document
  include ActiveModel::Serializers::JSON

  field :name, type: String
  field :slack_channel, type: String  # e.g. "shop-woodworking" — used for slash command routing
  field :disabled, type: Boolean, default: false

  has_many :tools, dependent: :destroy

  validates :name, presence: true, uniqueness: true
end
