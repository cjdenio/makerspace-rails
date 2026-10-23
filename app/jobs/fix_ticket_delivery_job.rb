class FixTicketDeliveryJob < ApplicationJob
  queue_as :default
  # Longer than the complete eight-attempt retry schedule. Renewed on enqueue,
  # each attempt and the running lease heartbeat; recovers lost async workers.
  CHAIN_TTL = 24.hours
  around_enqueue :reserve_delivery_chain
  retry_on StandardError, wait: :polynomially_longer, attempts: 8 do |job, error|
    job.send(:release_delivery_chain)
    raise error
  end
  def perform(ticket_id)
    ticket = FixTicket.where(id: ticket_id).first
    return unless ticket
    # Also adopts jobs queued before the marker was deployed. A stale job whose
    # reservation was replaced exits without starting another retry chain.
    return unless claim_delivery_chain
    FixTicketDeliveryLease.with(ticket_id, check_owner: -> { raise Error::Conflict.new('Delivery chain replaced') unless renew_delivery_chain }) do
      FixTicketEvent.where(ticket_id: ticket.id, completed_at: nil).order_by(revision: :asc).each do |event|
        FixTicketDelivery.call(ticket.reload, event)
      end
    end
    release_delivery_chain
    # Catch events committed after the worker opened its cursor but before it
    # released the reservation. Later commits can enqueue themselves normally.
    self.class.perform_later(ticket_id) if FixTicketEvent.where(ticket_id: ticket.id, completed_at: nil).exists?
  end

  private

  def ticket_selector = { _id: FixTicketId.mongoize(arguments.first) }
  def chain_selector = ticket_selector.merge(delivery_job_id: job_id)
  def chain_deadline = [Time.current, scheduled_at || Time.current].max + CHAIN_TTL
  def claim_delivery_chain
    FixTicket.collection.find(ticket_selector.merge('$or' => [
      { delivery_job_id: nil }, { delivery_job_id: job_id }, { delivery_job_until: { '$lt' => Time.current } }
    ])).update_one('$set' => { delivery_job_id: job_id, delivery_job_until: chain_deadline }).matched_count == 1
  end
  def renew_delivery_chain
    FixTicket.collection.find(chain_selector).update_one('$set' => { delivery_job_until: chain_deadline }).matched_count == 1
  end
  def release_delivery_chain
    FixTicket.collection.find(chain_selector).update_one('$unset' => { delivery_job_id: '', delivery_job_until: '' })
  end
  def reserve_delivery_chain
    return unless claim_delivery_chain
    begin
      yield
      release_delivery_chain unless successfully_enqueued?
    rescue StandardError
      release_delivery_chain
      raise
    end
  end
end
