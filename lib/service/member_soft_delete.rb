module Service
  # Soft-deletes ("ghosts") a duplicate/abandoned Member account -- e.g. a
  # member who couldn't access their original account/email and signed up a
  # second time. The record is never destroyed: history (invoices, audit
  # log, etc.) keeps resolving, but it's excluded from normal queries via
  # Member's default_scope and its email frees up for reuse. Never sends any
  # notification to the member -- this is an internal cleanup action.
  #
  # This is NOT how you revoke a member's access. Revocation is done by
  # changing the `status` field on their member profile page (e.g. to
  # "revoked"), which blocks their email from being reused for a new
  # signup -- the opposite of what soft-delete does. Soft-delete is only for
  # cleaning up a duplicate/abandoned account, and refuses to run at all on
  # a member with an active, unexpired membership or a live subscription
  # (see Member#eligible_for_soft_delete?), so it can't be used as a
  # shortcut for revocation even by mistake.
  module MemberSoftDelete
    class ActiveMembershipError < StandardError; end
    class AlreadyDeletedError < StandardError; end
    class NotDeletedError < StandardError; end

    def self.delete!(member, actor:)
      raise AlreadyDeletedError, "#{member.fullname} is already deleted" if member.merged_at.present?
      unless member.eligible_for_soft_delete?
        raise ActiveMembershipError,
          "#{member.fullname} has an active, unexpired membership or a live subscription and cannot be deleted"
      end

      before = member.attributes.dup

      Service::MemberAccess.full_deprovision(member)
      member.update_attribute(:merged_at, Time.current)

      Service::AuditLogger.log(
        log_type:        'member',
        event_type:      'member_soft_deleted',
        resource_type:   'Member',
        resource_id:     member.id,
        actor:           actor,
        subject:         member,
        before_snapshot: before,
        after_snapshot:  member.attributes,
        message_details: "#{actor&.fullname || 'An admin'} marked #{member.fullname} (#{member.email}) as deleted.",
        slack_channel:   ::Service::SlackConnector.logs_channel
      )

      member
    end

    def self.restore!(member, actor:)
      raise NotDeletedError, "#{member.fullname} is not deleted" if member.merged_at.blank?

      before = member.attributes.dup
      member.update_attribute(:merged_at, nil)

      Service::AuditLogger.log(
        log_type:        'member',
        event_type:      'member_restored',
        resource_type:   'Member',
        resource_id:     member.id,
        actor:           actor,
        subject:         member,
        before_snapshot: before,
        after_snapshot:  member.attributes,
        message_details: "#{actor&.fullname || 'An admin'} restored #{member.fullname}'s (#{member.email}) account.",
        slack_channel:   ::Service::SlackConnector.logs_channel
      )

      member
    end
  end
end
