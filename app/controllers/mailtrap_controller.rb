class MailtrapController < ApplicationController
  protect_from_forgery except: [:webhooks]

  def webhooks
    raw_body = request.raw_post
    return unless valid_mailtrap_signature?(raw_body)

    payload = JSON.parse(raw_body)
    process_events(Array.wrap(payload["events"]))

    render json: {}, status: :ok and return
  rescue JSON::ParserError => e
    Rails.logger.error("[Mailtrap] Failed to parse webhook payload: #{e.message}")
    render json: { error: "Invalid JSON payload" }, status: :bad_request and return
  end

  private

  def valid_mailtrap_signature?(raw_body)
    secret = ENV["MAILTRAP_WEBHOOK_SIGNATURE"].to_s
    return true if secret.blank?

    provided_signature = request.headers["Mailtrap-Signature"].to_s
    computed_signature = OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body)
    return true if secure_compare(provided_signature, computed_signature)

    Rails.logger.error("[Mailtrap] Webhook signature validation failed")
    render json: { error: "Invalid signature" }, status: :unauthorized and return false
  end

  def secure_compare(left, right)
    return false if left.blank? || right.blank? || left.bytesize != right.bytesize

    ActiveSupport::SecurityUtils.secure_compare(left, right)
  end

  # Higher index = higher priority. Negative events always win over positive
  # so admins can see bounces/spam even if a delivery was recorded earlier.
  EVENT_PRIORITY = {
    'delivery'    => 1,
    'open'        => 2,
    'click'       => 3,
    'unsubscribe' => 10,
    'soft bounce' => 10,
    'spam'        => 10,
    'bounce'      => 11,
    'suspension'  => 11,
    'reject'      => 11,
  }.freeze

  def process_events(events)
    events.each do |event|
      next unless event.is_a?(Hash)

      recipient_email = event['email'].to_s.strip
      next if recipient_email.blank?

      member = Member.where(email: /\A#{Regexp.escape(recipient_email)}\z/i).first
      next unless member

      mailtrap_event = MailtrapEvent.create!(mailtrap_attributes(event).merge(member_id: member.id))

      # Link to MailtrapMessage if one was captured at send time (subject, mailer context)
      if mailtrap_event.message_id.present?
        msg = MailtrapMessage.where(message_id: mailtrap_event.message_id).first
        mailtrap_event.set(mailtrap_message_id: msg.id) if msg
      end

      # Only update the member's displayed event if this one outranks the current one.
      # This prevents a bot-triggered 'open' from overwriting a clean 'delivery' record,
      # but always lets negative events (bounce, spam) surface.
      current_event = member.mailtrap_event
      new_priority     = EVENT_PRIORITY.fetch(mailtrap_event.event.to_s, 0)
      current_priority = current_event ? EVENT_PRIORITY.fetch(current_event.event.to_s, 0) : -1

      member.set(mailtrap_id: mailtrap_event.id) if new_priority >= current_priority
    end
  end

  def mailtrap_attributes(event)
    attributes = event.deep_dup.deep_transform_keys(&:underscore)
    attributes["status"] = attributes["status"].presence || attributes["event"]
    attributes["occurred_at"] = parse_timestamp(attributes["timestamp"])
    attributes["raw_payload"] = attributes.deep_dup
    attributes.slice(
      "email",
      "status",
      "occurred_at",
      "event",
      "event_id",
      "message_id",
      "response",
      "sending_stream",
      "sending_domain_name",
      "timestamp",
      "raw_payload"
    )
  end

  def parse_timestamp(value)
    return if value.blank?

    zone = Time.zone || ActiveSupport::TimeZone["UTC"]
    zone.at(value.to_i)
  end
end
