class Tool
  include Mongoid::Document
  include ActiveModel::Serializers::JSON

  field :name, type: String
  field :wiki_url, type: String
  field :gdrive_id, type: String
  field :description, type: String
  field :disabled, type: Boolean, default: false
  field :allow_pending, type: Boolean, default: false
  field :announce, type: Boolean, default: false
  field :announce_channel, type: String
  field :users_channel, type: String
  # Optional prerequisite tool IDs — UI warns if member hasn't been checked out on these
  field :prerequisite_ids, type: Array, default: []
  field :reservable, type: Boolean, default: false
  field :max_concurrent_reservations, type: Integer, default: 1
  field :reservation_horizon_days, type: Integer, default: 7
  field :max_reservation_duration_hours, type: Float, default: 8.0
  field :reservation_requires_approval, type: Boolean, default: false
  field :reservation_prerequisite_tool_ids, type: Array, default: []
  field :google_resource_id, type: String
  field :resource_email, type: String

  belongs_to :shop

  before_validation :normalize_external_fields
  after_save :warm_changed_slack_channel_cache

  validates :name, presence: true
  validates :name, uniqueness: { case_sensitive: false }
  validates :shop, presence: true
  validates :max_concurrent_reservations, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :reservation_horizon_days, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :max_reservation_duration_hours, numericality: { greater_than: 0 }
  validate :reservation_duration_uses_half_hours
  validate :reservation_prerequisites_belong_to_shop

  index({ name: 1 }, {
    unique: true,
    collation: { locale: 'en', strength: 2 },
    partial_filter_expression: { name: { '$type' => 'string' } }
  })

  def disabled
    value = read_attribute(:disabled)
    value.nil? ? false : value
  end

  def reservable
    value = read_attribute(:reservable)
    value.nil? ? false : value
  end

  def effective_wiki_url
    wiki_url.to_s.strip.presence || WikiUrlBuilder.tool_url(shop&.name, name)
  end

  def allow_pending
    value = read_attribute(:allow_pending)
    value.nil? ? false : value
  end

  def effective_reservation_prerequisite_ids
    (Array(reservation_prerequisite_tool_ids).map(&:to_s) + [id.to_s]).reject(&:blank?).uniq
  end

  def reservation_prerequisites
    Tool.where(:id.in => effective_reservation_prerequisite_ids)
  end

  # Human-readable prerequisite names for display
  def prerequisites
    prerequisite_ids.present? ? Tool.where(:id.in => prerequisite_ids) : []
  end

  private

  def normalize_external_fields
    self.wiki_url = wiki_url.to_s.strip.presence
    self.gdrive_id = gdrive_id.to_s.strip.presence
    self.announce_channel =
      Service::SlackChannelCache.normalize_name(announce_channel).presence
    self.users_channel =
      Service::SlackChannelCache.normalize_name(users_channel).presence
  end

  def warm_changed_slack_channel_cache
    return if Rails.env.test?

    %w[announce_channel users_channel].each do |field|
      next unless previous_changes.key?(field)

      channel_name = public_send(field)
      Service::SlackChannelCache.lookup(
        channel_name,
        refresh_on_miss: true
      ) if channel_name.present?
    end
  end

  def reservation_duration_uses_half_hours
    value = max_reservation_duration_hours.to_f
    errors.add(:max_reservation_duration_hours, "must use half-hour increments") unless (value * 2).round == value * 2
  end

  def reservation_prerequisites_belong_to_shop
    ids = Array(reservation_prerequisite_tool_ids).map(&:to_s).uniq
    return if ids.empty? || shop_id.blank?

    valid_ids = Tool.where(shop_id: shop_id, :id.in => ids).pluck(:id).map(&:to_s)
    errors.add(:reservation_prerequisite_tool_ids, "must belong to this shop") unless (ids - valid_ids).empty?
  end
end
