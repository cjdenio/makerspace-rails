class Permission
  include Mongoid::Document

  field :name, type: String
  field :enabled, type: Boolean, default: false

  validates :name, presence: true

  belongs_to :member

  def self.list_permissions
    self.distinct(:name)
  end
end