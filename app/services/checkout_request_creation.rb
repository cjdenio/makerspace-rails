class CheckoutRequestCreation
  def self.create!(member_id:, tool_id:, shop_id:, note: nil, defer_notifications: false)
    request = CheckoutMutationLock.with(member_id: member_id, tool_id: tool_id) do
      yield if block_given?
      member = Member.find_by(id: member_id)
      tool = Tool.find_by(id: tool_id)
      raise Error::UnprocessableEntity.new("Tool unavailable") unless member && tool && tool.shop_id.to_s == shop_id.to_s
      policy = ToolCheckoutRequestEligibility.new(member: member, tool: tool)
      if (error = policy.error)
        error_class = policy.membership_ineligible? ? Error::Forbidden : Error::UnprocessableEntity
        raise error_class.new(error)
      end
      ToolCheckoutRequest.create!(member: member, tool: tool, note: note, request_date: Time.current, status: "open")
    end
    if defer_notifications
      CheckoutNotificationJob.enqueue("request", request.id)
    else
      CheckoutCreation.notify { request.announce_request }
      CheckoutCreation.notify { request.notify_requestor }
    end
    request
  end
end
