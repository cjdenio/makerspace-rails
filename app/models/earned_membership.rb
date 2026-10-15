class EarnedMembership
  include Mongoid::Document
  include Mongoid::Search
  include ActiveModel::Serializers::JSON
  include Service::SlackConnector

  store_in collection: 'earned_memberships'

  STATUSES = %w[active suspended].freeze

  belongs_to :member, class_name: 'Member'
  has_many :requirements, class_name: 'EarnedMembership::Requirement', dependent: :destroy
  has_many :reports, class_name: 'EarnedMembership::Report', dependent: :destroy

  field :status, type: String, default: 'active'
  field :status_changed_at, type: Time

  search_in member: %i[firstname lastname email], requirements: :name

  accepts_nested_attributes_for :requirements, reject_if: :reject_requirements, allow_destroy: true

  validates :member, presence: true
  validates_inclusion_of :status, in: STATUSES
  validate :one_to_one
  # Only relevant on create or when (re)activating -- a suspended record must
  # never be blocked by the member's own subscription, since converting to a
  # paid subscription is exactly the normal reason to suspend one (#257).
  validate :existing_subscription, if: -> { new_record? || (status_changed? && active?) }
  validate :requirements_exist

  after_save :set_member_expiration, if: :active?

  scope :active, -> { where(status: 'active') }

  def active?
    status == 'active'
  end

  def suspended?
    status == 'suspended'
  end

  # Deactivates this record without running the usual validations (none are
  # relevant to a pure status flip, and existing_subscription would otherwise
  # block the exact case this exists for -- see the validation above) or the
  # renewal callback. History (requirements, reports) is untouched.
  def suspend!(actor)
    return if suspended?

    before = attributes.dup
    set(status: 'suspended', status_changed_at: Time.current)
    ::Service::AuditLogger.log(
      log_type:        'member',
      event_type:      'earned_membership_suspended',
      resource_type:   'EarnedMembership',
      resource_id:     id,
      actor:           actor,
      subject:         member,
      before_snapshot: before,
      after_snapshot:  attributes
    )
  end

  # Full validation path (unlike suspend!) -- existing_subscription must run
  # here, so reactivating an earned membership for a member currently on a
  # paid subscription is rejected rather than silently double-covering them.
  def reactivate!(actor)
    return if active?

    before = attributes.dup
    update!(status: 'active', status_changed_at: Time.current)
    ::Service::AuditLogger.log(
      log_type:        'member',
      event_type:      'earned_membership_reactivated',
      resource_type:   'EarnedMembership',
      resource_id:     id,
      actor:           actor,
      subject:         member,
      before_snapshot: before,
      after_snapshot:  attributes
    )
  end

  def outstanding_requirements
    requirements.select do |requirement|
      requirement.current_term && !requirement.current_term.satisfied && requirement.current_term.end_date < member.pretty_time
    end
  end

  def evaluate_for_renewal
    # Find requirements not satisfied and that are not in future terms.
    # Guarded by active? as defense-in-depth -- the only path that can drive
    # a term to satisfaction is report submission, already blocked while
    # suspended at the controller level (see #257).
    renew_member if active? && outstanding_requirements.size == 0
  end

  def self.search(searchTerms, criteria = Mongoid::Criteria.new(EarnedMembership))
    criteria.full_text_search(searchTerms)
  end

  private
  def get_shortest_term_end_time
    min_req = requirements.min_by(&:term_length)
    return nil if min_req.nil?
    min_req_term = min_req.current_term
    min_req_term && min_req_term.end_date.to_i * 1000
  end

  def one_to_one
    member_memberships = EarnedMembership.where(member_id: self.member_id)
    # memberships exist and aren't this one
    if member_memberships.size > 0 && !(member_memberships.size == 1 && member_memberships.first.id == self.id)
      errors.add(:member, "Earned membership already exists for member #{member_memberships.first.member.fullname}")
    end
  end

  def existing_subscription
    if !self.member.nil? && (self.member.subscription || self.member.subscription_id)
      errors.add(:member, "#{self.member.fullname} is still on subscription. Must cancel subscription first")
    end
  end

  def renew_member
    before = self.member.attributes.dup
    self.member.update(expirationTime: get_shortest_term_end_time)
    time = self.member.pretty_time.strftime("%m/%d/%Y")
    ::Service::SlackConnector.send_slack_message("#{self.member.fullname} earned membership extended to #{time}")
    ::Service::AuditLogger.log(
      log_type:        "member",
      event_type:      "earned_membership_renewed",
      resource_type:   "Member",
      resource_id:     self.member.id,
      subject:         self.member,
      field_changes:   self.member.previous_changes,
      before_snapshot: before,
      after_snapshot:  self.member.attributes
    )
  end

  def requirements_exist
    if self.requirements.nil? or self.requirements.size == 0
      errors.add(:requirements, "required")
    end
  end

  def set_member_expiration
    if get_shortest_term_end_time && get_shortest_term_end_time > (self.member.get_expiration || 0)
      renew_member
    end
  end

  def reject_requirements(attributes)
    exists = attributes['id'].present?

    # Sanitize null, empty IDs and raise errors for any invalid
    if exists
      related_requirement = Requirement.find(attributes['id'])
      if related_requirement.nil?
        raise ::Mongoid::Errors::DocumentNotFound.new(Requirement, { id: attributes['id'] })
      end
    else
      attributes.delete('id')
    end

    empty = attributes.except('id').values.all?(&:blank?)
    attributes.merge!({:_destroy => 1}) if exists and empty # destroy empty requirement
    return (!exists and empty) # reject empty attributes
  end
end