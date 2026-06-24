class Group
  include Mongoid::Document
  include InvoiceableResource
  include Service::SlackConnector

  field :groupRep            # primary member's fullname (display only)
  field :groupName, type: String  # primary member's MongoDB ID (unique key)
  field :expiry, type: Integer    # expiration in ms, propagated to all household members
  field :subscription_id, type: String
  field :subscription, type: Boolean, default: false

  belongs_to :member, primary_key: 'fullname', foreign_key: "groupRep"
  has_many :active_members, class_name: "Member", inverse_of: :group, primary_key: 'groupName', foreign_key: "groupName"

  # Override member to use direct ID lookup since fullname is not a stored field
  def member
    Member.find(self.groupName) rescue nil
  end

  validates :groupName, presence: true, uniqueness: true
  validates :groupRep, presence: true
  validate :primary_on_household_plan, on: :create

  after_update :update_active_members
  after_create :update_active_members

  def group_display_name
    "#{groupRep}'s Household"
  end

  def add_subordinate(subordinate_member)
    validate_address_match!(subordinate_member)
    subordinate_member.update_attributes!({ 
      groupName: self.groupName,
      expirationTime: self.expiry  # directly set expiry regardless of current state
    })
    update_active_members
  end

  def remove_subordinate(subordinate_member)
    # Revert to their own invoice's expiration if available
    own_invoice = Invoice.where(
      resource_class: "member",
      resource_id: subordinate_member.id.to_s
    ).where(:plan_id.nin => [nil, ""], :plan_id.not => /household/)
     .order_by(created_at: :desc).first

    own_expiration = own_invoice&.due_date ? (own_invoice.due_date.to_i * 1000) : nil
    subordinate_member.update_attributes!({ groupName: nil, expirationTime: own_expiration })
  end

  # InvoiceableResource interface
  def expiration_attr
    :expiry
  end

  def base_slack_message
    "#{groupRep}'s household membership"
  end

  def update_expiration(new_expiration)
    self.update_attributes!(expiry: new_expiration)
    self.member.update_attributes!(expirationTime: new_expiration) if self.member
    self.active_members.where(:id.ne => self.groupName).each do |m|
      m.update_attributes!(expirationTime: new_expiration)
    end
  end

  # Emit to Member & Management channels on renewal. Matches the pattern
  # used by Member/Rental — queued via enque_message with distinct
  # uniquifiers per recipient, not the synchronous send_slack_message this
  # codebase has been moving away from (see #91).
  def send_renewal_slack_message(current_user = nil)
    slack_user = SlackUser.find_by(member_id: member.id) if member
    unless slack_user.nil?
      enque_message(
        get_renewal_slack_message,
        slack_user.slack_id,
        ::Service::SlackConnector.request_caller_id("send_renewal_slack_message.member.#{id}")
      )
    end
    enque_message(
      get_renewal_slack_message(current_user),
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("send_renewal_slack_message.management.#{id}")
    )
  end

  def send_renewal_reversal_slack_message
    slack_user = SlackUser.find_by(member_id: member.id) if member
    unless slack_user.nil?
      enque_message(
        get_renewal_reversal_slack_message,
        slack_user.slack_id,
        ::Service::SlackConnector.request_caller_id("send_renewal_reversal_slack_message.member.#{id}")
      )
    end
    enque_message(
      get_renewal_reversal_slack_message,
      ::Service::SlackConnector.members_relations_channel,
      ::Service::SlackConnector.request_caller_id("send_renewal_reversal_slack_message.management.#{id}")
    )
  end

  def remove_subscription
    update_attributes!({ subscription_id: nil, subscription: false })
  end

  private

  def update_active_members
    self.active_members.each { |m| m.verify_group_expiry }
    self.member.verify_group_expiry if self.member
  end

  def primary_on_household_plan
    primary = self.member
    return unless primary
    invoice = Invoice.where(resource_class: "member", resource_id: primary.id.to_s)
                     .order_by(created_at: :desc).first
    unless invoice&.plan_id&.include?("household")
      errors.add(:base, "Primary member must be on a household membership plan")
    end
  end

  def validate_address_match!(subordinate_member)
    primary = self.member
    return unless primary

    primary_street = primary.address_street.to_s.strip.downcase
    primary_postal = primary.address_postal_code.to_s.strip
    sub_street     = subordinate_member.address_street.to_s.strip.downcase
    sub_postal     = subordinate_member.address_postal_code.to_s.strip

    unless primary_street == sub_street && primary_postal == sub_postal
      raise ::Error::UnprocessableEntity.new(
        "Secondary member's address does not match the primary member's address. " \
        "Please update the secondary member's address before linking."
      )
    end
  end
end
