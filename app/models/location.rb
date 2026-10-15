class Location
  include Mongoid::Document

  field :name, type: String
  field :kind, type: String            # free text: "cabinet", "shelf", "area", etc. -- not a fixed enum
  field :parent_id, type: BSON::ObjectId, default: nil
  field :svg_element_id, type: String, default: nil   # references a named shape in the shop's existing floor-plan SVG
  field :x_pct, type: Float, default: nil             # fallback click-placed pin, % of image width
  field :y_pct, type: Float, default: nil             # % of image height
  field :shape_points, type: Array, default: nil      # admin-drawn polygon: [{x:, y:}, ...], % of image
  # Which floor plan this location's percentages are relative to. Blank means
  # "the shop's own floor", so existing records need no migration and a shop
  # that spans floors (e.g. Facilities) just sets it per location.
  field :floor_name, type: String, default: nil
  # Marker glyph for the map; blank draws the default pin.
  field :icon, type: String, default: nil

  # Keep in step with the glyph set in the React map.
  ICONS = %w[pin cabinet shelf drawer workbench saw drill printer laser welder sewing electronics hand_tools lathe].freeze

  belongs_to :shop

  validates :name, presence: true
  validates :shop, presence: true
  validates :x_pct, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :y_pct, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true
  validates :floor_name, inclusion: { in: Shop::FLOOR_NAMES }, allow_nil: true
  validates :icon, inclusion: { in: ICONS }, allow_nil: true
  before_validation :normalize_blank_floor_and_icon
  before_validation :inherit_parent_floor
  validate :parent_belongs_to_same_shop
  validate :floor_matches_parent
  before_update :remember_floor_change
  after_update :cascade_floor_to_descendants
  validate :parent_is_not_a_descendant
  validate :shape_points_form_a_polygon
  validate :shape_points_within_bounds

  index({ shop_id: 1 })
  index({ parent_id: 1 })

  # The floor plan this location is drawn on.
  def effective_floor_name
    floor_name.presence || shop&.floor_name
  end

  def parent
    Location.find(parent_id) if parent_id
  end

  def children
    Location.where(parent_id: id)
  end

  def tools
    Tool.where(location_id: id)
  end

  # Every location nested under this one, at any depth -- used so deleting
  # a location can cascade (clear tool links, remove child locations)
  # instead of leaving descendants behind with a parent_id pointing at a
  # now-deleted document.
  def descendants
    children.flat_map { |child| [child] + child.descendants }
  end

  private

  def normalize_blank_floor_and_icon
    self.floor_name = nil if floor_name.blank?
    self.icon = nil if icon.blank?
  end

  # A nested cabinet or shelf is drawn on its parent's floor.
  def inherit_parent_floor
    return if floor_name.present? || parent_id.blank?

    parent_floor = Location.where(id: parent_id).only(:floor_name).first&.floor_name
    self.floor_name = parent_floor if parent_floor.present?
  end

  def floor_matches_parent
    return unless parent_id

    parent_location = Location.where(id: parent_id).first
    return unless parent_location && effective_floor_name != parent_location.effective_floor_name

    errors.add(:floor_name, "must match the floor of the parent location")
  end

  # Mongoid has already cleared its dirty tracking by the time after_update
  # runs, so note the change while it is still visible.
  def remember_floor_change
    @floor_changed = floor_name_changed?
  end

  # Moving a location to another floor moves everything nested in it.
  def cascade_floor_to_descendants
    return unless @floor_changed

    @floor_changed = false
    descendants.each { |child| child.set(floor_name: floor_name) }
  end

  def parent_belongs_to_same_shop
    return unless parent_id
    parent_location = Location.where(id: parent_id).first
    errors.add(:parent_id, "must belong to the same shop") if parent_location && parent_location.shop_id != shop_id
  end

  # Only relevant when re-parenting an existing location -- a brand new
  # record can't already be an ancestor of anything. Walks up the chain with
  # a visited-set guard so a pre-existing cycle in the data can't hang this
  # in an infinite loop.
  def parent_is_not_a_descendant
    return unless parent_id && persisted?
    visited = Set.new
    ancestor = Location.where(id: parent_id).first
    while ancestor
      if ancestor.id == id || visited.include?(ancestor.id)
        errors.add(:parent_id, "cannot be a descendant of this location")
        return
      end
      visited << ancestor.id
      ancestor = ancestor.parent_id ? Location.where(id: ancestor.parent_id).first : nil
    end
  end

  def shape_points_form_a_polygon
    return if shape_points.nil?
    errors.add(:shape_points, "must have at least 3 points to form a shape") if shape_points.size < 3
  end

  def shape_points_within_bounds
    return if shape_points.nil?
    out_of_bounds = shape_points.any? do |point|
      point = point.to_h
      x, y = point[:x] || point["x"], point[:y] || point["y"]
      x.nil? || y.nil? || x.to_f < 0 || x.to_f > 100 || y.to_f < 0 || y.to_f > 100
    end
    errors.add(:shape_points, "must have x/y values between 0 and 100") if out_of_bounds
  end
end
