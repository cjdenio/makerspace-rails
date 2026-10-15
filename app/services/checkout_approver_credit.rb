require "digest"

# Awards and reverses the silent credit attached to a checkout completed by an
# ordinary, individually assigned checkout approver.
class CheckoutApproverCredit
  VALUE = 0.25

  def self.award!(checkout)
    actor = checkout.approved_by
    return unless additional_approver?(actor, checkout.tool)
    return if checkout.volunteer_credit_id.present?

    credit = VolunteerCredit.find_or_create_by!(tool_checkout_id: checkout.id) do |row|
      row.member_id = actor.id
      row.issued_by_id = actor.id
      row.description = "Completed checkout for #{checkout.member.fullname} on #{checkout.group_name.presence || checkout.tool.name}"
      row.credit_value = VALUE
      row.status = "approved"
    end
    checkout.set(volunteer_credit_id: credit.id)
    credit
  end

  def self.reverse!(checkout)
    return reverse_under_lock!(checkout) unless checkout.approval_batch_id.present?
    CheckoutMutationLock.with(member_id: 'group-credit', tool_id: checkout.approval_batch_id) do
      reverse_under_lock!(checkout)
    end
  end

  def self.reverse_under_lock!(checkout)
    credit = VolunteerCredit.find_by(id: checkout.volunteer_credit_id) ||
      VolunteerCredit.find_by(tool_checkout_id: checkout.id)
    return unless credit&.status == "approved" && !credit.reversed

    now = Time.current
    reversed_by = Member.find_by(id: checkout.revoked_by_id) || Member.find_by(id: credit.issued_by_id)
    reversed_by_id = reversed_by&.id || credit.issued_by_id
    reversal = VolunteerCredit.find_or_initialize_by(id: reversal_id_for(credit))
    reversal.assign_attributes(
      member_id: credit.member_id,
      issued_by_id: credit.issued_by_id,
      description: "Reversal: #{credit.description}",
      credit_value: -credit.credit_value,
      status: "reversal",
      reversal_of_id: credit.id,
      reversal_reason: "Tool checkout revoked",
      reversed_by_id: reversed_by_id,
      reversed_at: now,
      earned_while_em_active: credit.earned_while_em_active
    )
    reversal.save! if reversal.new_record?
    credit.update!(reversed: true, reversed_by_id: reversed_by_id, reversed_at: now)
    if credit.discount_applied
      credit.send(:notify_braintree_review_needed, reversed_by, "Tool checkout revoked") if reversed_by
    end
  end

  def self.additional_approver?(actor, tool)
    return false unless actor && tool
    return false if actor.role.in?(%w[admin board_member]) || actor.manages_shop?(tool.shop_id)

    CheckoutApprover.find_by(member_id: actor.id)&.can_approve_tool?(tool) || false
  end

  # The deterministic ObjectId makes the reversal insert uniquely keyed by the
  # original credit. If a failure occurs before the original is marked reversed,
  # a retry reuses the already-persisted offset instead of creating another one.
  def self.reversal_id_for(credit)
    digest = Digest::SHA256.hexdigest("checkout-approver-credit-reversal/#{credit.id}")
    BSON::ObjectId.from_string(digest.first(24))
  end
  private_class_method :additional_approver?, :reversal_id_for
end
