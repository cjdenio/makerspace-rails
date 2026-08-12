class VolunteerCredit
  include Mongoid::Document
  include Mongoid::Timestamps
  include Service::SlackConnector

  store_in collection: 'volunteer_credits'

  # Core associations
  field :member_id,     type: BSON::ObjectId
  field :issued_by_id,  type: BSON::ObjectId
  field :task_id,       type: BSON::ObjectId, default: nil

  # Credit details
  field :description,   type: String
  field :credit_value,  type: Float, default: 1.0

  # Lifecycle status
  # pending   — submitted, awaiting approval
  # approved  — verified, counts toward threshold
  # rejected  — denied by admin/RM
  # reversal  — negative offsetting record created when an approved credit is reversed
  field :status, type: String, default: 'pending'

  # Discount tracking
  field :discount_applied,    type: Boolean, default: false
  field :discount_applied_at, type: Time,    default: nil

  # Reversal tracking (on the original credit)
  field :reversed,        type: Boolean,       default: false
  field :reversed_by_id,  type: BSON::ObjectId, default: nil
  field :reversed_at,     type: Time,           default: nil

  # Reversal record fields (populated on the negative offsetting record only)
  field :reversal_of_id,  type: BSON::ObjectId, default: nil
  field :reversal_reason, type: String,          default: nil

  validates :member_id,    presence: true
  validates :description,  presence: true
  validates :credit_value, numericality: { other_than: 0 }  # 0 invalid; negative allowed for reversal records
  validates_inclusion_of :status, in: %w[pending approved rejected reversal]

  validate :approver_is_not_self

  index({ member_id: 1 })
  index({ status: 1 })
  index({ created_at: 1 })

  # ── Scopes ────────────────────────────────────────────────────────────────

  scope :approved,  -> { where(status: 'approved') }
  scope :pending,   -> { where(status: 'pending') }
  scope :rejected,  -> { where(status: 'rejected') }
  scope :reversals, -> { where(status: 'reversal') }
  scope :this_year, -> { where(:created_at.gte => Time.now.beginning_of_year) }

  # ── Class Methods ─────────────────────────────────────────────────────────

  # Total net credits for a member this year.
  # Includes approved credits (positive) and reversal records (negative),
  # so reversals automatically reduce the count with no extra logic.

  # Total net lifetime credits for a member (all time).
  def self.lifetime_count_for(member_id)
    where(status: { '$in' => ['approved', 'reversal'] })
      .where(member_id: member_id)
      .sum(:credit_value).to_f
  end

  # Total net credits for a member in the last X days.
  # Used for rolling counter display and future Slack promo channel eligibility checks.
  def self.rolling_count_for(member_id, days)
    where(status: { '$in' => ['approved', 'reversal'] })
      .where(:created_at.gte => days.to_i.days.ago)
      .where(member_id: member_id)
      .sum(:credit_value).to_f
  end

  def self.year_count_for(member_id)
    where(status: { '$in' => ['approved', 'reversal'] })
      .this_year
      .where(member_id: member_id)
      .sum(:credit_value).to_f
  end

  # Number of discounts already applied to a member this calendar year.
  # Excludes credits that have been reversed so a manual Braintree correction
  # can free up cap space if needed.
  def self.discounts_applied_this_year_for(member_id)
    threshold = [credits_per_discount, 1].max.to_f
    applied_sum = approved.this_year
                          .where(member_id: member_id, discount_applied: true, reversed: false)
                          .sum(:credit_value).to_f
    (applied_sum / threshold).floor
  end

  def self.credits_per_discount
    (SystemConfig.get('volunteer_credits_per_discount') || 8).to_f
  end

  def self.max_discounts_per_year
    (SystemConfig.get('volunteer_max_discounts_per_year') || 2).to_i
  end

  def self.discount_id
    SystemConfig.get('volunteer_discount_id').presence
  end

  def self.pending_slack_channel
    SystemConfig.get('volunteer_pending_slack_channel') || 'general'
  end

  # ── Instance Methods ──────────────────────────────────────────────────────

  def member
    Member.find(member_id)
  end

  def issued_by
    Member.find(issued_by_id) if issued_by_id
  end

  def task
    VolunteerTask.find(task_id) if task_id
  end

  def approve!(approver)
    raise Error::Forbidden.new if approver.id == member_id
    update!(status: 'approved', issued_by_id: approver.id)
    notify_member_credit_awarded
    check_discount_threshold!
  end

  def reject!(approver)
    raise Error::Forbidden.new if approver.id == member_id
    update!(status: 'rejected', issued_by_id: approver.id)
  end

  # Reverse an approved credit.
  # Creates a negative offsetting record in the same collection for full
  # audit trail. Marks the original credit as reversed. Notifies the member
  # via Slack DM. If the credit contributed to a Braintree discount,
  # flags the treasurer channel for manual Braintree review.
  #
  # Only admin/board members can call this (enforced in the controller).
  # Cannot reverse a credit that is already reversed or not approved.
  def reverse!(reversed_by, reason)
    raise Error::Forbidden.new unless status == 'approved'
    raise Error::Forbidden.new if reversed

    # Create the negative offsetting record
    reversal = VolunteerCredit.new(
      member_id:       member_id,
      issued_by_id:    reversed_by.id,
      description:     "Reversal: #{description}",
      credit_value:    -credit_value,
      status:          'reversal',
      reversal_of_id:  id,
      reversal_reason: reason,
      reversed_by_id:  reversed_by.id,
      reversed_at:     Time.now
    )
    reversal.save!

    # Mark the original credit as reversed
    update!(
      reversed:       true,
      reversed_by_id: reversed_by.id,
      reversed_at:    Time.now
    )

    notify_member_credit_reversed(reversed_by, reason)
    notify_braintree_review_needed(reversed_by, reason) if discount_applied

    reversal
  end

  private

  def approver_is_not_self
    if issued_by_id && issued_by_id == member_id && status == 'approved'
      errors.add(:issued_by_id, 'cannot approve their own credit')
    end
  end

  # DM the member when their credit is approved.
  # Also sends a subscription nudge if discounts are configured but no subscription.
  def notify_member_credit_awarded
    m          = member
    year_total = VolunteerCredit.year_count_for(m.id)
    slack_user = SlackUser.find_by(member_id: m.id)
    return unless slack_user

    common = ::Service::EmailTemplate.common_variables(m)
    message = ::Service::EmailTemplate.render(
      :volunteer_credit_awarded,
      common.merge(
        credit_description: description,
        credit_value: credit_value,
        year_total: year_total,
        credit_plural: year_total == 1.0 ? 'credit' : 'credits'
      ),
      fallback: true,
      format: :text
    )

    if VolunteerCredit.discount_id.present? && !m.subscription_id.present?
      threshold      = VolunteerCredit.credits_per_discount
      discounts_used = VolunteerCredit.discounts_applied_this_year_for(m.id)
      max_discounts  = VolunteerCredit.max_discounts_per_year

      unless discounts_used >= max_discounts
        next_threshold = threshold * (discounts_used + 1)
        credits_needed = [next_threshold - year_total, 0].max

        if credits_needed == 0
          message += "\n\n" + ::Service::EmailTemplate.render(
            :volunteer_credit_discount_earned, common, fallback: true, format: :text
          )
        elsif credits_needed <= 1.0
          message += "\n\n" + ::Service::EmailTemplate.render(
            :volunteer_credit_discount_progress,
            common.merge(
              credits_needed: credits_needed,
              credit_plural: credits_needed == 1.0 ? 'credit' : 'credits'
            ),
            fallback: true,
            format: :text
          )
        end
      end
    end

    ::Service::SlackConnector.send_slack_message(message, slack_user.slack_id)
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end

  # DM the member when one of their credits is reversed
  def notify_member_credit_reversed(reversed_by, reason)
    m          = member
    slack_user = SlackUser.find_by(member_id: m.id)
    return unless slack_user

    message = ::Service::EmailTemplate.render(
      :volunteer_credit_reversed,
      ::Service::EmailTemplate.common_variables(m).merge(
        credit_description: description,
        credit_value: credit_value.abs,
        credit_plural: credit_value.abs == 1.0 ? 'credit' : 'credits',
        reason: reason,
        reversed_by_name: reversed_by.fullname
      ),
      fallback: true,
      format: :text
    )
    ::Service::SlackConnector.send_slack_message(message, slack_user.slack_id)
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end

  # Notify the treasurer channel when a reversed credit had triggered a discount,
  # so they can manually review and adjust Braintree billing cycles if appropriate.
  def notify_braintree_review_needed(reversed_by, reason)
    m          = member
    message = ::Service::EmailTemplate.render(
      :volunteer_braintree_review,
      ::Service::EmailTemplate.common_variables(m).merge(
        reversed_by_name: reversed_by.fullname,
        reason: reason
      ),
      fallback: true,
      format: :text
    )
    ::Service::SlackConnector.send_slack_message(message, ::Service::SlackConnector.treasurer_channel)
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end

  # Check if this credit crosses the discount threshold and apply Braintree discount.
  # Skips reversal records entirely — they are accounting offsets, not new credits.
  def check_discount_threshold!
    return if status == 'reversal'
    return if VolunteerCredit.discount_id.blank?

    m = member
    return if EarnedMembership.where(member_id: m.id).exists?

    year_total     = VolunteerCredit.year_count_for(m.id)
    discounts_used = VolunteerCredit.discounts_applied_this_year_for(m.id)
    threshold      = VolunteerCredit.credits_per_discount
    max_discounts  = VolunteerCredit.max_discounts_per_year

    return if discounts_used >= max_discounts
    return unless year_total >= threshold * (discounts_used + 1)

    unless m.subscription_id.present?
      notify_no_subscription(m)
      return
    end

    # Atomically claim the first unmarked credit — race condition guard
    claimed_doc = VolunteerCredit.collection.find_one_and_update(
      {
        member_id:        member_id,
        status:           'approved',
        discount_applied: false,
        created_at:       { :$gte => Time.now.beginning_of_year }
      },
      { :$set => { discount_applied: true, discount_applied_at: Time.now } },
      sort:            { created_at: 1 },
      return_document: :before
    )
    return unless claimed_doc

    first_value = claimed_doc['credit_value'].to_f
    remaining   = threshold - first_value

    if remaining > 0
      VolunteerCredit.approved.this_year
                     .where(member_id: member_id, discount_applied: false)
                     .order_by(created_at: :asc)
                     .each do |credit|
        break if remaining <= 0
        credit.update!(discount_applied: true, discount_applied_at: Time.now)
        remaining -= credit.credit_value
      end
    end

    apply_braintree_discount(m)
  end

  def apply_braintree_discount(m)
    discount_id = VolunteerCredit.discount_id
    result      = BraintreeService::VolunteerDiscount.apply(m, discount_id, 1)

    if result == :no_subscription
      notify_no_subscription(m)
    else
      notify_discount_applied(m, result)
    end
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
    notify_discount_error(m, e)
  end

  def notify_discount_applied(m, discount_info)
    amount      = discount_info[:amount]
    cycles      = discount_info[:cycles_added]
    total       = discount_info[:total_cycles]
    description = discount_info[:description]
    id_str      = m.id.to_s
    cycles_str  = cycles == 1 ? '1 billing cycle' : "#{cycles} billing cycles"
    amount_str  = "$#{format('%.2f', amount)}/mo"

    slack_user = SlackUser.find_by(member_id: m.id)
    if slack_user
      member_message = ::Service::EmailTemplate.render(
        :volunteer_discount_applied_member,
        ::Service::EmailTemplate.common_variables(m).merge(amount: amount_str, billing_cycles: cycles_str),
        fallback: true,
        format: :text
      )
      ::Service::SlackConnector.send_slack_message(member_message, slack_user.slack_id)
    end

    admin_message = ::Service::EmailTemplate.render(
      :volunteer_discount_applied_admin,
      ::Service::EmailTemplate.common_variables(m).merge(
        member_id: id_str,
        amount: amount_str,
        billing_cycles: cycles_str,
        total_cycles: total,
        discount_description: description
      ),
      fallback: true,
      format: :text
    )
    ::Service::SlackConnector.send_slack_message(admin_message, ::Service::SlackConnector.treasurer_channel)
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
    notify_discount_error(m, e) rescue nil
  end

  def notify_no_subscription(m)
    message = ::Service::EmailTemplate.render(
      :volunteer_discount_no_subscription,
      ::Service::EmailTemplate.common_variables(m),
      fallback: true,
      format: :text
    )
    ::Service::SlackConnector.send_slack_message(message, ::Service::SlackConnector.logs_channel)
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end

  def notify_discount_error(m, error)
    message = ::Service::EmailTemplate.render(
      :volunteer_discount_error,
      ::Service::EmailTemplate.common_variables(m).merge(
        error_message: error.message
      ),
      fallback: true,
      format: :text
    )
    ::Service::SlackConnector.send_slack_message(message, ::Service::SlackConnector.logs_channel)
  rescue => e
    Honeybadger.notify(e) if defined?(Honeybadger)
  end
end
