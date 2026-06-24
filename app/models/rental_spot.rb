class RentalSpot
  include Mongoid::Document
  include Mongoid::Search
  include ActiveModel::Serializers::JSON

  field :number,            type: String   # e.g. "LR-Tote-1", "Shelf-1a"
  field :location,          type: String   # e.g. "Locker Room", "Back Shop"
  field :description,       type: String   # e.g. "Black Tote"
  field :rental_type_id,    type: String   # references RentalType._id
  field :requires_approval, type: Boolean, default: false
  field :active,            type: Boolean, default: true
  field :parent_number,     type: String   # set on child spots (e.g. "Shelf-1" for "Shelf-1a")
  field :notes,             type: String

  search_in :number, :location, :description

  validates :number,         presence: true, uniqueness: true,
                              format: { with: /\A[A-Za-z0-9_-]+\z/,
                                        message: "can only contain letters, numbers, hyphens, and underscores (no spaces or special characters), so it can be used in a rental deep link" }
  validates :location,       presence: true
  validates :rental_type_id, presence: true

  def rental_type
    return nil if rental_type_id.blank?
    RentalType.find(rental_type_id)
  rescue
    nil
  end

  def invoice_option
    rental_type&.invoice_option
  end

  def available?
    return false unless active?
    return false if currently_rented?
    return false if parent_rented?
    return false if children_rented?
    true
  end

  def currently_rented?
    Rental.where(number: number).where(
      "$or" => [
        { status: "active" },
        { status: "pending" }
      ]
    ).exists?
  end

  def parent_rented?
    return false if parent_number.blank?
    parent = RentalSpot.find_by(number: parent_number)
    return false if parent.nil?
    parent.currently_rented?
  end

  def children_rented?
    children = RentalSpot.where(parent_number: number)
    children.any?(&:currently_rented?)
  end

  def self.search(searchTerms, criteria = Mongoid::Criteria.new(RentalSpot))
    criteria.full_text_search(searchTerms)
  end
end
