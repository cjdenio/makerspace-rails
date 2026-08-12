class Shop
  include Mongoid::Document
  include ActiveModel::Serializers::JSON

  field :name, type: String
  field :wiki_url, type: String
  field :gdrive_id, type: String
  field :slack_channel, type: String  # e.g. "shop-woodworking" — used for slash command routing
  field :disabled, type: Boolean, default: false
  field :reservable, type: Boolean, default: false
  field :max_concurrent_reservations, type: Integer, default: 1
  field :reservation_horizon_days, type: Integer, default: 7
  field :max_reservation_duration_hours, type: Float, default: 8.0
  field :reservation_requires_approval, type: Boolean, default: false
  field :reservation_prerequisite_tool_ids, type: Array, default: []
  field :google_resource_id, type: String
  field :resource_email, type: String
  field :color_id, type: String, default: "1"
  field :canvas_today, type: String
  field :canvas_tomorrow, type: String
  field :volunteer_canvas_id, type: String

  has_many :tools, dependent: :destroy
  has_many :reservation_blackouts, dependent: :destroy

  before_validation :normalize_external_fields
  after_save :warm_changed_slack_channel_cache

  validates :name, presence: true, uniqueness: { case_sensitive: false }
  validates :max_concurrent_reservations, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :reservation_horizon_days, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :max_reservation_duration_hours, numericality: { greater_than: 0 }
  validates :color_id, format: { with: /\A\d+\z/, allow_blank: true }
  validate :reservation_duration_uses_half_hours
  validate :reservation_prerequisites_belong_to_shop

  index({ name: 1 }, {
    unique: true,
    collation: { locale: 'en', strength: 2 },
    partial_filter_expression: { name: { '$type' => 'string' } }
  })

  def reservable
    value = read_attribute(:reservable)
    value.nil? ? false : value
  end

  def effective_wiki_url
    wiki_url.to_s.strip.presence || WikiUrlBuilder.shop_url(name)
  end

  def reservation_prerequisites
    ids = Array(reservation_prerequisite_tool_ids).map(&:to_s)
    ids.present? ? Tool.where(:id.in => ids) : Tool.none
  end

  private

  def normalize_external_fields
    self.wiki_url = wiki_url.to_s.strip.presence
    self.gdrive_id = gdrive_id.to_s.strip.presence
    self.slack_channel = Service::SlackChannelCache.normalize_name(slack_channel).presence
  end

  def warm_changed_slack_channel_cache
    return if Rails.env.test?
    return unless previous_changes.key?("slack_channel")
    return if slack_channel.blank?

    Service::SlackChannelCache.lookup(
      slack_channel,
      refresh_on_miss: true
    )
  end

  def reservation_duration_uses_half_hours
    value = max_reservation_duration_hours.to_f
    errors.add(:max_reservation_duration_hours, "must use half-hour increments") unless (value * 2).round == value * 2
  end

  def reservation_prerequisites_belong_to_shop
    ids = Array(reservation_prerequisite_tool_ids).map(&:to_s).uniq
    return if ids.empty?

    valid_ids = Tool.where(shop_id: id, :id.in => ids).pluck(:id).map(&:to_s)
    errors.add(:reservation_prerequisite_tool_ids, "must belong to this shop") unless (ids - valid_ids).empty?
  end
end
