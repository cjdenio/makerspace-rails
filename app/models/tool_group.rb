class ToolGroup
  include Mongoid::Document
  include Mongoid::Timestamps

  belongs_to :shop
  field :name, type: String
  field :description, type: String
  field :prerequisite_ids, type: Array, default: []
  field :included_tool_ids, type: Array, default: []
  field :reservable, type: Boolean, default: false
  field :requestable, type: Boolean, default: false
  field :announce, type: Boolean, default: false
  field :announce_channel, type: String
  field :archived, type: Boolean, default: false
  field :revision, type: Integer, default: 1

  index({ shop_id: 1, name: 1 }, unique: true, collation: { locale: 'en', strength: 2 })
  index({ included_tool_ids: 1 })
  index({ prerequisite_ids: 1 })
  validates :shop, :name, presence: true
  validate :physical_members_in_shop
  validate :unique_catalog_name
  validate :fixed_shop
  before_validation :normalize_catalog_fields
  before_destroy :prepare_request_cleanup
  after_destroy :remove_request_announcements

  def included_tools
    Tool.where(:id.in => included_tool_ids).order_by(name: :asc).to_a
  end

  def self.referencing(tool_id)
    any_of({ included_tool_ids: tool_id.to_s }, { prerequisite_ids: tool_id.to_s })
  end

  def self.manageable_by?(member, shop_id)
    member && (member.role.in?(%w[admin board_member]) || member.manages_shop?(shop_id))
  end

  def disabled?
    archived? || shop.nil? || shop.disabled?
  end

  def effective_requestor_annotation
    shop&.requestor_annotation
  end

  # Preserve request history while removing pending work for an unavailable group.
  def close_open_requests!
    ToolCheckoutRequest.where(tool_group_id: id, status: 'open').update_all(status: 'deleted')
    CheckoutApproverRequest.where(tool_group_id: id, status: 'open').update_all(status: 'revoked')
  end

  private

  def prepare_request_cleanup
    @request_announcements = ToolCheckoutRequest.where(tool_group_id: id, status: 'open',
      :message_id.nin => [nil, '']).to_a
    @request_announcement_snapshot = {
      'name' => name, 'channel' => announce_channel.presence || shop&.slack_channel
    }
    close_open_requests!
  end

  def remove_request_announcements
    Array(@request_announcements).each do |request|
      CheckoutCreation.notify do
        request.reload
        request.remove_announcement(notification_snapshot: @request_announcement_snapshot) if request.status == 'deleted'
      end
    end
  end

  def normalize_catalog_fields
    self.name = name.to_s.strip
    self.included_tool_ids = Array(included_tool_ids).map(&:to_s).uniq
    self.prerequisite_ids = Array(prerequisite_ids).map(&:to_s).uniq
    self.announce_channel = Service::SlackChannelCache.normalize_name(announce_channel).presence
  end

  def fixed_shop
    errors.add(:shop, 'cannot be changed') if persisted? && shop_id_changed?
  end

  def physical_members_in_shop
    errors.add(:included_tool_ids, 'must include at least one physical tool') if included_tool_ids.empty?
    errors.add(:prerequisite_ids, 'must not overlap included tools') if (included_tool_ids & prerequisite_ids).any?
    requested = included_tool_ids | prerequisite_ids
    valid = Tool.where(shop_id: shop_id, :id.in => requested).pluck(:id).map(&:to_s)
    errors.add(:included_tool_ids, 'and prerequisites must be physical tools in this shop') unless (requested - valid).empty?
  end

  def unique_catalog_name
    collation = { locale: 'en', strength: 2 }
    if Tool.where(shop_id: shop_id, name: name).collation(collation).exists? ||
        self.class.where(shop_id: shop_id, name: name, :id.ne => id).collation(collation).exists?
      errors.add(:name, 'already exists in this shop')
    end
  end
end
