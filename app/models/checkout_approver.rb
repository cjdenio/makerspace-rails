class CheckoutApprover
  include Mongoid::Document
  include ActiveModel::Serializers::JSON

  belongs_to :member

  # Array of Shop IDs this approver can sign off checkouts for
  field :shop_ids, type: Array, default: []

  validates :member, presence: true

  def shops
    shop_ids.present? ? Shop.where(:id.in => shop_ids) : []
  end

  # Check if this approver can approve for a given shop
  def can_approve_for_shop?(shop_id)
    shop_ids.map(&:to_s).include?(shop_id.to_s)
  end

  # Check if a member is a checkout approver (any shop)
  def self.is_approver?(member_id)
    exists?(member_id: member_id)
  end

  # Get shops a member can approve for
  def self.shops_for_member(member_id)
    approver = find_by(member_id: member_id)
    approver ? approver.shops : []
  end
end
