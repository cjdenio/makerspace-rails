require 'rails_helper'

RSpec.describe FixTicketDeliveryRecoveryJob, type: :job do
  include ActiveJob::TestHelper
  let(:ticket) { create(:fix_ticket) }
  let!(:event) { FixTicketEvent.create!(ticket_id: ticket.id, kind: 'created', revision: 1) }
  before do
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end

  it 'deduplicates recovery and normal enqueues while queued or retrying without touching timestamps' do
    updated_at = ticket.reload.updated_at
    job = FixTicketDeliveryJob.perform_later(ticket.id.to_s)
    3.times { described_class.perform_now; FixTicketService.enqueue(ticket) }
    expect(enqueued_jobs.length).to eq(1)
    allow(FixTicketDelivery).to receive(:call).and_raise('Slack unavailable')
    clear_enqueued_jobs
    job.perform_now
    expect(enqueued_jobs.length).to eq(1)
    expect(enqueued_jobs.first['job_id']).to eq(job.job_id)
    3.times { described_class.perform_now }
    expect(enqueued_jobs.length).to eq(1)
    expect(ticket.reload.delivery_job_id).to eq(job.job_id)
    expect(ticket.updated_at).to eq(updated_at)
  end

  it 'allows only one enqueue when recoveries race' do
    ids = 4.times.map { Thread.new { job = FixTicketDeliveryJob.perform_later(ticket.id.to_s); job ? job.job_id : nil } }.map(&:value).compact
    expect(ids.length).to eq(1)
    expect(ticket.reload.delivery_job_id).to eq(ids.first)
  end

  it 'keeps one retry chain during a Redis lease conflict' do
    job = FixTicketDeliveryJob.perform_later(ticket.id.to_s)
    clear_enqueued_jobs
    allow(REDIS).to receive(:set).and_return(false)
    job.perform_now
    3.times { described_class.perform_now }
    expect(enqueued_jobs.length).to eq(1)
    expect(ticket.reload.delivery_job_id).to eq(job.job_id)
  end

  it 'stops a running worker and its retries when its persisted ownership changes' do
    job = FixTicketDeliveryJob.perform_later(ticket.id.to_s)
    clear_enqueued_jobs
    allow(FixTicketDelivery).to receive(:call) do
      ticket.set(delivery_job_id: 'replacement', delivery_job_until: 1.day.from_now)
      Thread.current[:fix_delivery_lease].call
      raise 'Lost worker continued'
    end
    job.perform_now
    expect(enqueued_jobs).to be_empty
    expect(ticket.reload.delivery_job_id).to eq('replacement')
    expect(event.reload.completed_at).to be_nil
  end

  it 'releases a failed enqueue for the next recovery run' do
    adapter = FixTicketDeliveryJob.queue_adapter
    allow(adapter).to receive(:enqueue).and_raise('Queue unavailable')
    expect { FixTicketDeliveryJob.perform_later(ticket.id.to_s) }.to raise_error('Queue unavailable')
    expect(ticket.reload.delivery_job_id).to be_nil
    allow(adapter).to receive(:enqueue).and_call_original
    described_class.perform_now
    expect(ticket.reload.delivery_job_id).to be_present
  end

  it 'clears exhausted retries so a later recovery can resume delivery' do
    job = FixTicketDeliveryJob.perform_later(ticket.id.to_s)
    allow(FixTicketDelivery).to receive(:call).and_raise('Slack unavailable')
    7.times { job.perform_now }
    expect { job.perform_now }.to raise_error('Slack unavailable')
    expect(ticket.reload.delivery_job_id).to be_nil
    described_class.perform_now
    expect(ticket.reload.delivery_job_id).to be_present
    expect(ticket.delivery_job_id).not_to eq(job.job_id)
  end

  it 'recovers abandoned reservations and fences stale jobs' do
    old = FixTicketDeliveryJob.perform_later(ticket.id.to_s)
    travel 25.hours do
      described_class.perform_now
      replacement = ticket.reload.delivery_job_id
      expect(replacement).not_to eq(old.job_id)
      expect(FixTicketDelivery).not_to receive(:call)
      old.perform_now
      expect(ticket.reload.delivery_job_id).to eq(replacement)
    end
  end

  it 'clears a successful chain and queues events that arrive during delivery' do
    job = FixTicketDeliveryJob.perform_later(ticket.id.to_s)
    clear_enqueued_jobs
    allow(FixTicketDelivery).to receive(:call) do |_ticket, pending|
      pending.set(completed_at: Time.current)
      FixTicketEvent.create!(ticket_id: ticket.id, kind: 'note', note: 'New note', revision: 2)
      described_class.perform_now # suppressed while this job still owns the chain
      expect(enqueued_jobs).to be_empty
    end
    job.perform_now
    expect(enqueued_jobs.length).to eq(1)
    expect(ticket.reload.delivery_job_id).not_to eq(job.job_id)
  end
end
