class FixTicketDeliveryRecoveryJob < ApplicationJob
  queue_as :default
  def perform
    FixTicketEvent.where(completed_at: nil).distinct(:ticket_id).each do |id|
      # The delivery job atomically reserves its persisted retry chain before
      # enqueueing; recovery does not add jobs while that reservation is live.
      FixTicketDeliveryJob.perform_later(id.to_s)
    end
  end
end
