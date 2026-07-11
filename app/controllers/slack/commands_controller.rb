# Handles inbound Slack slash commands.
#
# Slack sends a POST to /slack/commands when a slash command is used.
# The payload includes: command, text, channel_name, user_id, user_name
#
# Response must be returned within 3 seconds (Slack timeout).
# All processing is deferred to jobs to avoid the timeout.
#
# Commands:
#   /checkout @member tool-name   — tool checkout (SlackCheckoutJob)
#   /volunteer <subcommand>       — volunteer credits/tasks (SlackVolunteerJob)
#
class Slack::CommandsController < ApplicationController
  include Service::SlackConnector
  skip_before_action :verify_authenticity_token
  before_action :verify_slack_signature

  def checkout
    text = params[:text].to_s.strip

    parts = text.split(/\s+/, 2)
    if parts.length < 2
      render json: {
        response_type: 'ephemeral',
        text: 'Usage: `/checkout @member tool-name` or `/checkout email@example.com tool-name`'
      } and return
    end

    member_token = parts[0]
    tool_name    = parts[1]

    SlackCheckoutJob.perform_later(params.to_unsafe_h.stringify_keys)

    render json: {
      response_type: 'ephemeral',
      text: "Processing checkout of *#{tool_name}* for *#{member_token}*..."
    }
  end

  def volunteer
    SlackVolunteerJob.perform_later(params.to_unsafe_h.stringify_keys)

    render json: {
      response_type: 'ephemeral',
      text: 'Processing your volunteer command...'
    }
  end

  private

  # Verify the request actually came from Slack using signing secret
  def verify_slack_signature
    slack_signing_secret = ENV['SLACK_SIGNING_SECRET']
    return if slack_signing_secret.blank? # Skip in dev if not configured

    timestamp = request.headers['X-Slack-Request-Timestamp']
    signature = request.headers['X-Slack-Signature']
    body      = request.raw_post

    # Reject if timestamp is >5 minutes old (replay attack prevention)
    if (Time.now.to_i - timestamp.to_i).abs > 300
      render json: { error: 'Request too old' }, status: 403 and return
    end

    sig_basestring = "v0:#{timestamp}:#{body}"
    my_signature   = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', slack_signing_secret, sig_basestring)}"

    unless ActiveSupport::SecurityUtils.secure_compare(my_signature, signature.to_s)
      render json: { error: 'Invalid signature' }, status: 403
    end
  end
end
