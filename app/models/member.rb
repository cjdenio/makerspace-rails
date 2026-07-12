class Member
  include Mongoid::Document
  include SanitizesUserInput
  include Mongoid::Search
  include ActiveModel::Serializers::JSON
  include InvoiceableResource
  include Service::SlackConnector
  include Publishable

  # Include default devise modules. Others available are:
  # :confirmable, :lockable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :timeoutable, :validatable

  # Overrides Devise::Models::Timeoutable#timeout_in so the idle-timeout
  # duration is looked up fresh from SystemConfig on every request, instead
  # of being fixed once at boot (see config/initializers/devise.rb). This
  # lets admins change it from the settings UI without an app restart, and
  # keeps the DB lookup out of app boot entirely.
  def timeout_in
    minutes = Integer(SystemConfig.get('devise_timeout_minutes').presence || 30)
    [minutes, 1].max.minutes
  rescue ArgumentError, TypeError
    30.minutes
  end

  field :cardID # TODO: I think this can be removed since its an assoc now. Doorboto checks card collection directly
  field :firstname
  field :lastname
  field :phone
  field :address_street
  field :address_unit
  field :address_city
  field :address_state
  field :address_postal_code

  field :status,                         default: "activeMember" # activeMember, nonMember, revoked, inactive
  field :expirationTime,  type: Integer  #pre-calcualted time of expiration
  field :startDate, default: -> { Time.now }
  field :groupName, type: String #potentially member is in a group/partner membership
  field :role,                          default: "member" #admin,board_member,resource_manager,member
  field :firebase_uid,                   type: String

  ## TOTP / Two-Factor Authentication
  field :otp_secret_encrypted,   type: String   # AES-256-CBC encrypted base32 secret
  field :otp_required_for_login, type: Boolean, default: false
  field :otp_enabled_at,         type: Time
  field :session_token,          type: String   # Rotated on TOTP reset to invalidate sessions
  field :member_contract_signed_date, type: Date
  field :subscription,    type: Boolean,   default: false
  ## Database authenticatable
  field :email,              type: String, default: ""
  field :encrypted_password, type: String, default: ""
  ## Recoverable
  field :reset_password_token,   type: String
  field :reset_password_sent_at, type: Time
  ## Rememberable - Handles cookies
  field :remember_created_at, type: Time

  field :customer_id, type: String # Braintree customer relation
  field :subscription_id, type: String # Braintree relation
  field :mailtrap_id, type: BSON::ObjectId
  field :silence_emails, type: Boolean # Stop marketing emails to user
  field :notes, type: String

  search_in :email, :lastname
  search_in :firstname, index: :_firstname_keywords

  validates :firstname, presence: true
  validates :lastname, presence: true
  validates :email, uniqueness: true
  validates :email, email_deliverability: true, unless: :skip_email_deliverability_validation
  validates :cardID, uniqueness: true, allow_nil: true
  validates_inclusion_of :status, in: ["activeMember", "nonMember", "revoked", "inactive", "suspended"]
  validates_inclusion_of :role, in: ["admin", "board_member", "resource_manager", "member"]

  before_validation :normalize_email, :normalize_group_name
  after_initialize :verify_group_expiry
  after_create :apply_default_permissions, :publish_create
  after_update :update_card, :handle_successful_email_change, :publish_update, :check_household_exit, :sync_expiration_to_group
  after_destroy :publish_destroy

  has_many :permissions, class_name: 'Permission', dependent: :destroy, :autosave => true
  has_many :rentals, class_name: 'Rental'
  has_many :invoices, class_name: "Invoice"
  has_many :access_cards, class_name: "Card", inverse_of: :member
  belongs_to :group, class_name: "Group", inverse_of: :active_members, optional: true, primary_key: 'groupName', foreign_key: "groupName"

  attr_accessor :skip_email_deliverability_validation, :current_invoice_operation

  def groupName
    value = read_attribute(:groupName)
    value.present? ? value.to_s : value
  end

  def groupName=(value)
    write_attribute(:groupName, value.present? ? value.to_s : nil)
  end

  def household_role
    return nil unless groupName.present?
    return :primary if self.id.to_s == groupName.to_s
    :secondary
  end

  def direct_notifications_suppressed?
    %w[revoked suspended].include?(status)
  end

  has_one :earned_membership, class_name: 'EarnedMembership', dependent: :destroy
  has_one :slack_user, class_name: 'SlackUser'
  # mailtrap_id on Member points to MailtrapEvent._id — modelled as belongs_to
  # so includes(:mailtrap_event) can bulk-load in one query instead of one per member.
  belongs_to :mailtrap_event, class_name: 'MailtrapEvent', foreign_key: :mailtrap_id, optional: true

  # Searches members using Atlas $search if available, falls back to case-insensitive
  # regex queries for local/CI environments where Atlas Search is not supported.
  # Regex.escape prevents special characters from breaking the query.
  # Returns Mongoid criteria matching members by full name "Firstname Lastname"
  # Used as fallback when Atlas Search is unavailable (local/CI).
  def self.name_search_criteria(searchTerms, criteria = Mongoid::Criteria.new(Member))
    terms = searchTerms.strip.split(/\s+/, 2)
    if terms.length == 2
      first_regex = /#{::Regexp.escape(terms[0])}/i
      last_regex  = /#{::Regexp.escape(terms[1])}/i
      # Match "Firstname Lastname" or "Lastname Firstname"
      criteria.any_of(
        { firstname: first_regex, lastname: last_regex },
        { firstname: last_regex,  lastname: first_regex }
      )
    else
      regex = /#{::Regexp.escape(searchTerms)}/i
      criteria.any_of({ lastname: regex }, { firstname: regex }, { email: regex })
    end
  end

  # SECURITY: `criteria` MUST be scoped to the caller's authorization context.
  # The default (Member.all) is intentionally unscoped for the one legitimate
  # admin-only callsite (Admin::Billing::SubscriptionsController) that needs
  # to search across all members. Any new callsite that does not pass an
  # explicit criteria will silently search all members regardless of the
  # caller's role — always pass a scoped criteria from the controller.
  def self.search(searchTerms, criteria = Member.all)
    regex = /#{::Regexp.escape(searchTerms)}/i

    if !!(searchTerms =~ URI::MailTo::EMAIL_REGEXP)
      # Email search
      pipeline = [
        {
          :$search => {
            index: "Searcher",
            text: {
              query: searchTerms,
              path: "email"
            }
          }
        },
        {
          :$sort => {
            score: { :$meta => "searchScore" }
          }
        },
        {
          :$project => {
            _id: 1,
          }
        }
      ]
      begin
        results = Member.collection.aggregate(pipeline)
        result_ids = results.collect { |r| r[:_id] }
        if result_ids.empty?
          # Atlas Search returned nothing — fall back to regex contains match
          return criteria.any_of({ email: regex })
        end
        members = criteria.where(id: { :$in => result_ids })
        return members.sort_by { |m| result_ids.to_a.index m.id }
      rescue Mongo::Error::OperationFailure
        # Atlas Search not available (local/CI) — fall back to regex contains match
        return criteria.any_of({ email: regex })
      end
    else
      # Name/general search
      pipeline = [
        {
          :$search => {
            index: "Searcher",
            text: {
              query: searchTerms,
              path: ["lastname", "firstname", "email"],
              fuzzy: {} # Empty object enables fuzzy searching
            }
          },
        },
        {
          :$sort => {
            score: { :$meta => "searchScore" }
          }
        },
        {
          :$project => {
            _id: 1,
          }
        }
      ]
      begin
        results = Member.collection.aggregate(pipeline)
        result_ids = results.collect { |r| r[:_id] }
        if result_ids.empty?
          # Atlas Search returned nothing — fall back to name search
          return Member.name_search_criteria(searchTerms, criteria)
        end
        members = criteria.where(id: { :$in => result_ids })
        return members.sort_by { |m| result_ids.to_a.index m.id }
      rescue Mongo::Error::OperationFailure
        # Atlas Search not available (local/CI) — fall back to name search
        return Member.name_search_criteria(searchTerms, criteria)
      end
    end
  end

  # Incorporate session_token so rotating it invalidates all existing Devise sessions
  def authenticatable_salt
    "#{super}#{session_token}"
  end

  def fullname
    return "#{self.firstname} #{self.lastname}"
  end

  def active_unexpired?
    status == 'activeMember' && expirationTime.present? && expirationTime > (Time.now.to_i * 1000)
  end

  def valid_for_checkout_request?
    active_unexpired? && member_contract_signed_date.present?
  end

  def normalize_email
    self.email = self.email.to_s.strip.downcase
  end

  def normalize_group_name
    self.groupName = self.groupName.to_s if self.groupName.present?
  end


  
  def verify_group_expiry
    return unless self.group
    # Primary member drives the group expiry — don't overwrite their expiration
    return if household_role == :primary
    # Only sync if this is a persisted record and the value actually needs updating.
    # after_initialize fires on every instantiation (including reads), so without
    # this guard save + all after_update callbacks (update_card, publish_update, etc.)
    # would fire on every Member.find.
    return unless persisted? && benefits_from_group
    new_expiry = self.group.expiry
    return if self.expirationTime == new_expiry
    self.expirationTime = new_expiry
    self.save
  end

  def address=(address_hash)
    unless address_hash.nil?
      self.update_attributes!({
        address_street: address_hash[:street] || self.address_street,
        address_unit: address_hash[:unit] || self.address_unit,
        address_city: address_hash[:city] || self.address_city,
        address_state: address_hash[:state] || self.address_state,
        address_postal_code: address_hash[:postal_code] || self.address_postal_code,
      })
    end
  end

  def memberContractOnFile=(onFile)
    if onFile && member_contract_signed_date.nil?
      self.update_attributes!({ member_contract_signed_date: Date.today })
    elsif !onFile
      self.update_attributes!({ member_contract_signed_date: nil })
    end
  end

  # Find the subscribed resource (instance of Member | Rental) for member
  # Since subscriptions aren't stored in our db, we'll check the subscribed resources
  # to verify ownership
  def find_subscribed_resource(id)
    resource = self if self.subscription_id && self.subscription_id == id
    resource = self.rentals.detect { |r| r.subscription_id == id } unless resource || self.rentals.nil?
    # Household subscriptions are billed on the Group, not the Member —
    # without this, a primary household member managing their own
    # household_* subscription via self-service (Billing::SubscriptionsController)
    # would 404, since their group was never considered here.
    group = Group.find_by(groupName: groupName) if resource.nil? && household_role == :primary
    resource = group if resource.nil? && group && group.subscription_id == id
    resource
  end

  def remove_subscription
    self.update_attributes!({ subscription_id: nil, subscription: false })
    notify_orphaned_rental_subscriptions
  end

  # Fires immediately when a membership subscription is cancelled or lapses.
  # Checks whether the member has any active rental subscriptions that are
  # now orphaned — i.e. the member is still being billed for a rental despite
  # having no active membership.
  #
  # Does NOT cancel the rental automatically — payment failures can cause
  # temporary lapses and we want admin review before taking destructive action.
  # The weekly member_review task surfaces these for follow-up.
  def notify_orphaned_rental_subscriptions
    orphaned = rentals.select do |r|
      r.subscription_id.present? &&
      %w[active vacating pending_agreement].include?(r.status)
    end
    return if orphaned.empty?

    now_ms    = Time.now.to_i * 1000
    lapsed    = expirationTime.nil? ||
                expirationTime < now_ms ||
                status != 'activeMember'
    return unless lapsed

    member_url = "#{Rails.configuration.action_mailer.default_url_options[:host]}/members/#{id}"
    rental_list = orphaned.map { |r| "##{r.number}" }.join(', ')

    ::Service::SlackConnector.send_slack_message(
      "⚠️ Membership subscription cancelled for <#{member_url}|#{fullname}> — " \
      "but they have active rental subscription(s): #{rental_list}. " \
      "The rental subscription(s) are still billing. Manual review required.",
      ::Service::SlackConnector.members_relations_channel
    )
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end

  def get_permissions
    Hash[permissions.map { |p| [p.name.to_sym, p.enabled] }]
  end

  def update_permissions(permissions_collection)
    permissions_collection.each_pair do |name, enabled|
      permission = permissions.detect { |p| p.name.to_sym == name.to_sym}
      if permission
        permission.update!(enabled: enabled)
      else
        Permission.new(name: name.to_sym, enabled: enabled, member_id: self.id).upsert
      end
    end
  end

  def is_allowed?(permission_name)
    permissions.detect { |p| p.name.to_s == permission_name.to_s && !!p.enabled }
  end

  def delay_invoice_operation(operation)
    if operation.to_sym == :renew=
      (self.access_cards || []).length == 0
    end
  end

  # Emit to Member & Management channels on renewal
  def send_renewal_slack_message(current_user=nil)
    slack_user = SlackUser.find_by(member_id: id)
    # NOTE: enque_message's default uniquifier is derived only from the
    # calling method name + Current.request_id — both calls below happen
    # within this same method in the same request, so without an explicit,
    # distinct uniquifier per call they'd write to the same Redis key and
    # the second REDIS.set would silently overwrite the first, losing one
    # of the two renewal notifications every time.
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

  # Emit to Member & Management channels on renewal reversals
  def send_renewal_reversal_slack_message
    slack_user = SlackUser.find_by(member_id: id)
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

  protected
  def base_slack_message
    self.fullname
  end

  def expiration_attr
    :expirationTime
  end

  # Devise hook — prevents revoked/suspended members from signing in.
  def active_for_authentication?
    super && !%w[revoked suspended].include?(status)
  end

  # Returns the i18n key used by DeviseFailure to build the error message.
  def inactive_message
    case status
    when 'revoked'   then :revoked
    when 'suspended' then :suspended
    else super
    end
  end

  private
  def update_card
    self.access_cards.each do |c|
      c.update(expiry: self.expirationTime)
    end
  end

  def check_household_exit
    # If a secondary household member just got their own subscription, remove them from the household
    return unless previous_changes.key?("subscription_id") && subscription_id.present?
    return unless household_role == :secondary

    group = Group.find_by(groupName: groupName)
    return unless group

    group.remove_subordinate(self)
  end

  def sync_expiration_to_group
    return unless previous_changes.key?("expirationTime")
    return unless household_role == :primary
    group = Group.find_by(groupName: groupName)
    return unless group

    if current_invoice_operation.nil? || household_invoice_operation? || group.expiry == self.expirationTime
      group.update_expiration(self.expirationTime)
    else
      disband_household_after_individual_renewal(group)
    end
  end

  def household_invoice_operation?
    current_invoice_operation&.plan_id.to_s.include?("household")
  end

  def disband_household_after_individual_renewal(group)
    members = group.active_members.to_a
    old_expiry = group.expiry

    cancel_active_household_subscription(group)

    members.each do |member|
      if member.id == self.id
        member.update_attributes!(groupName: nil)
      else
        member.update_attributes!(groupName: nil, expirationTime: old_expiry)
      end
    end

    group.destroy
    notify_household_disbanded(members)
  end

  def cancel_active_household_subscription(group)
    return unless group.subscription_id.present?

    gateway = ::Service::BraintreeGateway.connect_gateway
    ::BraintreeService::Subscription.cancel(gateway, group.subscription_id)
  end

  def notify_household_disbanded(members)
    members.each do |member|
      primary = member.id == self.id
      message = if primary
                  "Your Manchester Makerspace household membership has been disbanded because your account was renewed with an individual membership plan."
                else
                  "Your Manchester Makerspace household membership has been disbanded because the primary household member renewed with an individual membership plan. Please elect a new membership plan before your current expiration date."
                end

      slack_user = SlackUser.find_by(member_id: member.id)
      ::Service::SlackConnector.send_slack_message(message, slack_user.slack_id) if slack_user
      MemberMailer.household_disbanded(member.id.to_s, self.id.to_s, primary).deliver_later
    end

    ::Service::SlackConnector.send_slack_message(
      "#{fullname}'s household membership was disbanded after renewal with an individual membership plan.",
      ::Service::SlackConnector.members_relations_channel
    )
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end

  def benefits_from_group
    return self.group.expiry &&
           self.expirationTime &&
           self.group.expiry > (Time.now.strftime('%s').to_i * 1000) &&
           self.group.expiry > self.expirationTime
  end




  def email_required?
    false
  end

  def password_required?
    false
  end

  def publish_create
    # Invite to Slack, Google
    publish(:create)
  end

  def publish_update
    publish(:billing_info_changed) if previous_changes.keys.any? { |attr| [:firstname, :lastname].include?(attr.to_sym) }
  end

  def handle_successful_email_change
    return unless previous_changes.key?("email")

    set(firebase_uid: nil, session_token: SecureRandom.hex)
  end

  def publish_destroy
    publish(:destroy)
  end

  def apply_default_permissions
    update_permissions(DefaultPermission.list_as_hash)
  end
end
