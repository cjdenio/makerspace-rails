class CheckoutNotificationJob < ApplicationJob
  queue_as :slack

  def self.enqueue(action, record_id)
    CheckoutCreation.notify do
      queued = perform_later(action, record_id.to_s)
      raise "Checkout notification enqueue aborted" unless queued
      queued
    end
  end

  def perform(action, record_id)
    CheckoutCreation.notify do
      case action
      when "approval"
        checkout = ToolCheckout.find_by(id: record_id)
        return unless checkout && checkout.member && checkout.tool
        CheckoutCreation.deliver_notifications(checkout, invite: true)
      when "request", "cancellation", "decline"
        request = ToolCheckoutRequest.find_by(id: record_id)
        return unless request && request.member && request.target
        if action == "request"
          request.announce_request if request.open?
          request.notify_requestor
        elsif action == "cancellation" && request.status == "deleted"
          request.remove_announcement
          CheckoutRequestReminder.finalize!(request)
        elsif action == "decline" && request.declined?
          request.notify_declined
          request.refresh_declined_announcement
          CheckoutRequestReminder.finalize!(request)
        end
      when "approver_volunteer", "approver_volunteer_decision"
        request = CheckoutApproverRequest.find_by(id: record_id)
        return unless request && request.member && request.target
        if action == "approver_volunteer" && request.open?
          CheckoutApproverVolunteering.deliver_request_notifications(request)
        elsif action == "approver_volunteer_decision" && request.status.in?(%w[approved declined])
          CheckoutApproverVolunteering.deliver_decision_notification(request)
        end
      end
    end
  end
end
