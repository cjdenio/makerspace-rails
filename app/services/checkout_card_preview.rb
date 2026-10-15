# What an approver sees after tapping a member's fob while checking them out on a
# tool or group: who the fob belongs to and whether they can be checked out on it.
# Only the fields needed to confirm the right person are returned; card internals
# (card id, version, release state) are never exposed here.
module CheckoutCardPreview
  def self.build(member:, tool:)
    # An existing open request is not a reason to refuse the checkout; approving
    # closes it, so it is ignored here as it is in the Slack approval flow.
    error = ToolCheckoutRequestEligibility.new(member: member, tool: tool, open_request_tool_ids: []).error
    missing = missing_names(member, Array(tool.prerequisite_ids))
    payload(member, error, missing)
  end

  # A group needs every included tool to be eligible and its prerequisites met; the
  # review is the same one the approval dialog shows.
  def self.build_for_group(member:, group:)
    review = ToolGroupCheckout.review(member: member, group: group)
    error = nil
    begin
      ToolGroupCheckout.validate_review!(review)
    rescue ::Error::CustomError => e
      error = e.message
    end
    payload(member, error, missing_names(member, review[:missing_prerequisite_ids]))
  rescue ::Error::CustomError => e
    payload(member, e.message, [])
  end

  def self.missing_names(member, prerequisite_ids)
    held = ToolCheckout.where(member_id: member.id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
    Tool.where(:id.in => prerequisite_ids.map(&:to_s) - held).pluck(:name)
  end

  def self.payload(member, error, missing)
    { memberId: member.id.to_s, name: member.fullname, status: member.status,
      expirationTime: member.expirationTime, eligible: error.nil?, error: error,
      unmetPrerequisites: missing }
  end
  private_class_method :missing_names, :payload
end
