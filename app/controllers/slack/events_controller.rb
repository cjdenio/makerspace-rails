class Slack::EventsController < ApplicationController
  EVENT_DEDUPLICATION_TTL = 7.days.to_i
  PROCESSING_STATE = 'processing'
  COMPLETED_STATE = 'completed'

  skip_before_action :verify_authenticity_token
  before_action :verify_slack_signature

  def create
    payload = JSON.parse(request.raw_post)
    return render json: { challenge: payload['challenge'] } if payload['type'] == 'url_verification'
    return head :ok unless payload['type'] == 'event_callback'

    event = payload['event'] || {}
    return head :ok unless %w[team_join user_change].include?(event['type'])

    event_id = payload['event_id'].to_s
    return render json: { error: 'Missing event_id' }, status: :bad_request if event_id.blank?

    deduplication_key = "slack_event/#{Digest::SHA256.hexdigest(event_id)}"
    acquisition = acquire_event(deduplication_key)
    return head :ok if acquisition == :completed
    return head :service_unavailable unless acquisition == :acquired

    begin
      # No durable job queue is configured, so processing happens before
      # acknowledging: if it fails, the dedup key is released and Slack's
      # own webhook redelivery (with backoff) is what retries the event.
      Service::SlackUserEvents.process(event, event_id: event_id)
      REDIS.set(deduplication_key, COMPLETED_STATE, xx: true, ex: EVENT_DEDUPLICATION_TTL)
    rescue
      REDIS.del(deduplication_key)
      raise
    end
    head :ok
  rescue JSON::ParserError
    render json: { error: 'Invalid JSON' }, status: :bad_request
  end

  private

  # A single, immediate check -- not a blocking wait. If another request is
  # already processing this event_id, respond 503 right away and let Slack's
  # retry-with-backoff come back later, rather than holding a Puma worker
  # thread hostage on a sleep loop hoping the first attempt finishes in time.
  def acquire_event(key)
    return :acquired if REDIS.set(key, PROCESSING_STATE, nx: true, ex: EVENT_DEDUPLICATION_TTL)
    return :completed if REDIS.get(key) == COMPLETED_STATE

    :in_progress
  end

  def verify_slack_signature
    secret = ENV['SLACK_SIGNING_SECRET']
    if secret.blank?
      render json: { error: 'Slack signing secret is not configured' }, status: :forbidden
      return
    end

    timestamp = request.headers['X-Slack-Request-Timestamp']
    signature = request.headers['X-Slack-Signature']
    if timestamp.blank? || (Time.now.to_i - timestamp.to_i).abs > 300
      render json: { error: 'Request too old' }, status: :forbidden
      return
    end

    expected = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "v0:#{timestamp}:#{request.raw_post}")}"
    unless ActiveSupport::SecurityUtils.secure_compare(expected, signature.to_s)
      render json: { error: 'Invalid signature' }, status: :forbidden
    end
  end
end
