# Turns a fob tapped on an approver's phone into the member it belongs to, for a
# checkout on one tool or one tool group. Nothing is created: the approver sees
# who it is and whether they can be checked out, then confirms with the normal
# checkout endpoints.
#
# Allowed for anyone who can approve checkouts for that tool or group (admin or
# board member, the shop's resource manager, an assigned approver), unlike
# /admin/cards/lookup, which is admin/board only and returns card-management data.
# The result is limited to what is needed to confirm the person.
#
# Every lookup is written to the audit log, whatever its outcome (found, refused,
# unknown fob, forbidden, bad input), with the target and the last four characters
# of the UID. Lookups are deliberately not throttled: a class of members may need
# checking out in one sitting.
class CheckoutFobLookup
  UID_FORMAT = /\A(?:[0-9A-F]{2})+\z/

  def self.call(actor:, uid:, tool_id: nil, tool_group_id: nil)
    new(actor, uid, tool_id, tool_group_id).call
  end

  def initialize(actor, uid, tool_id, tool_group_id)
    @actor = actor
    @uid = uid
    @tool_id = tool_id.presence
    @tool_group_id = tool_group_id.presence
  end

  def call
    @target = find_target
    authorize!
    validate_uid!
    card = find_card
    @member = card.member
    refuse!(:not_found, ::Error::NotFound.new) unless @member

    preview = if @target.is_a?(ToolGroup)
      CheckoutCardPreview.build_for_group(member: @member, group: @target)
    else
      CheckoutCardPreview.build(member: @member, tool: @target)
    end
    log(:found, eligible: preview[:eligible])
    preview
  rescue ::Error::CustomError => error
    log(@result || :error, error: error.message) unless @logged
    raise
  end

  private

  def find_target
    if @tool_id.nil? == @tool_group_id.nil?
      refuse!(:invalid_target, ::Error::UnprocessableEntity.new("Choose exactly one tool or group"))
    end
    target = @tool_id ? Tool.find(@tool_id) : ToolGroup.find(@tool_group_id)
    refuse!(:not_found, ::Error::NotFound.new) unless target
    target
  end

  def authorize!
    allowed = @target.is_a?(ToolGroup) ? ToolGroupCheckout.authorized?(@actor, @target) : CheckoutCreation.authorized?(@actor, @target)
    return if allowed

    refuse!(:forbidden, ::Error::Forbidden.new("You are not authorized to approve checkouts for this tool"))
  end

  def validate_uid!
    return if @uid.is_a?(String) && @uid.match?(UID_FORMAT)

    refuse!(:invalid_uid, ::Error::UnprocessableEntity.new("UID must be uppercase hexadecimal ASCII byte pairs."))
  end

  def find_card
    cards = Card.where(uid: @uid).limit(2).to_a
    refuse!(:not_found, ::Error::NotFound.new) if cards.empty?
    refuse!(:duplicate_uid, ::Error::Conflict.new("Duplicate UID records require administrator repair.")) if cards.length > 1

    # A fob reported lost or stolen must not identify its member to anyone.
    if %w[lost stolen].include?(cards.first.validity)
      refuse!(:lost_or_stolen, ::Error::UnprocessableEntity.new("This fob has been reported lost or stolen and cannot be used."))
    end
    cards.first
  end

  def refuse!(result, error)
    @result = result
    log(result, error: error.message)
    raise error
  end

  def log(result, extra = {})
    @logged = true
    name = @target&.name
    Service::AuditLogger.log(
      log_type: "member", event_type: "fob_checkout_lookup",
      resource_type: @target.is_a?(ToolGroup) ? "ToolGroup" : "Tool", resource_id: @target&.id || BSON::ObjectId.new,
      actor: @actor, subject: @member,
      after_snapshot: { result: result.to_s, target_name: name, uid_tail: @uid.to_s.last(4) }.merge(extra).compact,
      message_details: "#{name || 'unknown target'}: #{result}"
    )
  rescue => error
    Service::ErrorReporter.notify(error)
  end
end
