class ToolGroupCatalog
  def self.save!(actor:, attributes:, group: nil, revision: nil)
    shop_id = group&.shop_id || attributes[:shop_id]
    announcements = []
    saved_group = CatalogMutationLock.with([shop_id]) do
      actor.reload
      raise Error::Forbidden.new('You cannot manage this shop') unless ToolGroup.manageable_by?(actor, shop_id)
      group&.reload
      if group && group.revision != revision.to_i
        raise Error::Conflict.new('This group changed. Refresh before saving.')
      end
      # Existing timestamps belong to the channel before this edit, even when
      # the same save moves future announcements to another channel.
      announcement_channel = group&.announce_channel.presence || group&.shop&.slack_channel
      # Lock before opening the snapshot, and retain locks until grants commit.
      member_ids = group ? CheckoutApprover.where(tool_group_ids: group.id.to_s).pluck(:member_id) : []
      # Request holders share the revocation lock while their active checkouts
      # are used to reconcile a membership edit.
      if group && attributes.key?(:included_tool_ids)
        member_ids |= ToolCheckoutRequest.where(tool_group_id: group.id, status: 'open').pluck(:member_id)
      end
      with_approver_locks(member_ids.map(&:to_s).uniq.sort) do
        ToolGroup.with_session do |session|
          existing_id = group&.id
          session.with_transaction do
            announcements.clear # A transaction retry must replace delivery intents.
            group = existing_id ? ToolGroup.find(existing_id) : ToolGroup.new
            group.assign_attributes(attributes)
            group.revision += 1 if group.persisted?
            group.save!
            CheckoutApprover.where(tool_group_ids: group.id.to_s).each do |approver|
              if ToolCheckout.where(member_id: approver.member_id, :tool_id.in => group.included_tool_ids, :revoked_at.ne => nil).exists?
                approver.pull(tool_group_ids: group.id.to_s)
                next
              end
              CheckoutApprover.collection.find(_id: approver.id).update_one('$addToSet' => {
                'tool_ids' => { '$each' => group.included_tool_ids },
                'group_granted_tool_ids' => { '$each' => group.included_tool_ids }
              })
              approver.pull(tool_group_ids: group.id.to_s) if group.archived?
            end
            if group.archived?
              group.close_open_requests!
            elsif existing_id && group.previous_changes.key?('included_tool_ids')
              ToolCheckoutRequest.where(tool_group_id: group.id, status: 'open').pluck(:member_id).uniq.each do |member_id|
                ToolGroupCheckout.reconcile!(member_id, tool_group_id: group.id).each do |request|
                  snapshot = ToolGroupCheckout.notification_snapshot(group, request.member)
                  snapshot['channel'] = announcement_channel
                  announcements << [request, snapshot]
                end
              end
            end
          end
        ensure
          session.end_session
        end
      end
      group
    end
    announcements.each do |request, snapshot|
      CheckoutCreation.notify { request.refresh_closed_announcement(notification_snapshot: snapshot) }
    end
    saved_group
  end

  def self.with_approver_locks(member_ids, &block)
    return yield if member_ids.empty?

    CheckoutApproverMutationLock.with(member_id: member_ids.first) do
      with_approver_locks(member_ids.drop(1), &block)
    end
  end
  private_class_method :with_approver_locks
end
