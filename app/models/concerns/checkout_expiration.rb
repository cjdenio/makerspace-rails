module CheckoutExpiration
  extend ActiveSupport::Concern
  ZONE = ActiveSupport::TimeZone['America/New_York'].freeze

  included do
    field :expires_on, type: Date
    field :expiration_revision, type: Integer, default: 0
    field :expiration_notice_state, type: Hash, default: {}
    field :renewed_from_id, type: BSON::ObjectId
    field :superseded_by_id, type: BSON::ObjectId
    index({ revoked_at: 1, superseded_by_id: 1, expires_on: 1, member_id: 1 })
    before_create :assign_initial_expiration
  end

  class_methods do
    def current_checkouts
      where(revoked_at: nil, superseded_by_id: nil)
    end

    def valid_at(at = Time.current)
      current_checkouts.any_of({ expires_on: nil }, { :expires_on.gte => at.in_time_zone(ZONE).to_date })
    end

    def expired_at(at = Time.current)
      current_checkouts.where(:expires_on.lt => at.in_time_zone(ZONE).to_date)
    end

    def filtered_status(status)
      case status
      when 'active' then valid_at
      when 'expired' then expired_at
      when 'revoked' then where(:revoked_at.ne => nil)
      when 'history' then where(:superseded_by_id.ne => nil)
      else all
      end
    end

    # Must run inside the approval transaction and its member/tool lock.
    def supersede_expired!(checkout)
      predecessors = expired_at.where(member_id: checkout.member_id, tool_id: checkout.tool_id, :id.ne => checkout.id)
      previous = predecessors.order_by(checked_out_at: :desc).first
      return checkout unless previous
      checkout.update!(renewed_from_id: previous.id)
      predecessors.update_all(superseded_by_id: checkout.id)
      checkout
    end
  end

  def current_checkout?
    revoked_at.nil? && superseded_by_id.nil?
  end

  def expired?(at = Time.current)
    expires_on.present? && expires_on < at.in_time_zone(ZONE).to_date
  end

  def valid_through?(at)
    active? && (expires_on.nil? || at <= (expires_on + 1.day).in_time_zone(ZONE))
  end

  def checkout_training_plan_url
    tool&.checkout_training_plan_url.presence || (group_id && ToolGroup.find_by(id: group_id)&.checkout_training_plan_url)
  end

  def expiration_status
    return 'history' if superseded_by_id
    return 'revoked' if revoked_at
    expired? ? 'expired' : 'active'
  end

  private

  def assign_initial_expiration
    return if expires_on.present? || tool&.checkout_expiration_years.nil?
    self.expires_on = checked_out_at.in_time_zone(ZONE).to_date.advance(years: tool.checkout_expiration_years)
  end
end
