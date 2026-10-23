# Runs only after the checkout transaction commits. Never retain a Slack trigger.
class ToolGroupCheckoutNotificationJob < ApplicationJob
  queue_as :slack

  def self.enqueue(group_id, member_id, result)
    CheckoutCreation.notify do
      queued = perform_later(group_id.to_s, member_id.to_s,
        result[:checkouts].map { |row| row.id.to_s },
        result[:reconciled].map { |row| row.id.to_s }, result[:approval_batch_id], result.fetch(:notification_snapshot))
      raise 'Group checkout notification enqueue aborted' unless queued
      queued
    end
  end

  def perform(group_id, member_id, checkout_ids, request_ids, batch_id, snapshot = nil)
    CheckoutCreation.notify do
      ToolGroupCheckout.deliver_notifications(
        snapshot ? nil : ToolGroup.find_by(id: group_id), Member.find_by(id: member_id),
        checkouts: ToolCheckout.where(:id.in => checkout_ids).to_a,
        reconciled: ToolCheckoutRequest.where(:id.in => request_ids, status: 'closed').to_a,
        approval_batch_id: batch_id, notification_snapshot: snapshot)
    end
  end
end
