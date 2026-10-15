class ToolGroupVolunteering
  def self.eligible!(member, group)
    raise Error::UnprocessableEntity.new('Group unavailable') if group.disabled?
    raise Error::UnprocessableEntity.new('An included tool is unavailable') if group.included_tools.any?(&:disabled?)
    raise Error::UnprocessableEntity.new('Membership must be active and current') unless member.valid_for_checkout_request?
    active = ToolCheckout.where(member_id: member.id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
    revoked = ToolCheckout.where(member_id: member.id, :revoked_at.ne => nil).pluck(:tool_id).map(&:to_s)
    unless (group.included_tool_ids - active).empty? && (group.included_tool_ids & revoked).empty?
      raise Error::UnprocessableEntity.new('You must have active checkouts for every included tool')
    end
  end

  def self.create!(member:, group:, note: nil)
    request = CatalogMutationLock.with([group.shop_id]) do
      group.reload
      ToolGroupCheckout.with_tool_locks(member.id, group.included_tool_ids) do
        member.reload
        eligible!(member, group)
        raise Error::UnprocessableEntity.new('You already approve this group') if CheckoutApprover.find_by(member_id: member.id)&.can_approve_group?(group)
        CheckoutApproverRequest.create!(member: member, tool_group: group, note: note)
      end
    end
    CheckoutNotificationJob.enqueue('approver_volunteer', request.id)
    request
  end

  def self.decide!(request:, actor:, approve:, note: nil)
    group = request.tool_group
    CatalogMutationLock.with([group.shop_id]) do
      CheckoutApproverMutationLock.with(member_id: request.member_id) do
        group.reload
        ToolGroupCheckout.with_tool_locks(request.member_id, group.included_tool_ids) do
          request.reload
          actor.reload
          raise Error::Forbidden.new unless CheckoutApproverVolunteering.reviewer?(actor, group.shop_id)
          raise Error::UnprocessableEntity.new('This request is no longer open') unless request.open?
          eligible!(request.member.reload, group) if approve
          CheckoutApprover.with_session do |session|
            session.with_transaction do
              if approve
                approver = CheckoutApprover.find_or_initialize_by(member_id: request.member_id)
                approver.tool_group_ids |= [group.id.to_s]
                approver.save!
              end
              request.update!(status: approve ? 'approved' : 'declined', decided_at: Time.current, decision_note: note)
            end
          ensure
            session.end_session
          end
        end
      end
    end
    CheckoutNotificationJob.enqueue('approver_volunteer_decision', request.id)
    request
  end
end
