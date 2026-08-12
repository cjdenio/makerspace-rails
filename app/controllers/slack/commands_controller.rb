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
#   /reserve                       — reserve a shop/tool in the current shop channel
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

  def reserve
    shop = Shop.find_by(slack_channel: params[:channel_name])
    unless shop
      render json: {
        response_type: "ephemeral",
        text: "No shop is configured for ##{params[:channel_name]}."
      } and return
    end

    slack_user = SlackUser.find_by(slack_id: params[:user_id])
    member = slack_user && Member.find_by(id: slack_user.member_id)
    unless member&.active_unexpired?
      render json: {
        response_type: "ephemeral",
        text: "Link an active Member Portal account before using /reserve."
      } and return
    end

    view = SlackReservationModal.build(shop, member)
    Service::SlackConnector.open_modal(params[:trigger_id], view)
    render json: { response_type: "ephemeral", text: "Opening reservation form…" }
  rescue ::Error::CustomError => error
    Rails.logger.warn(
      "[SlackReservationRejected] action=open_modal slack_user_id=#{params[:user_id]} reason=#{error.message}"
    )
    render json: { response_type: "ephemeral", text: error.message }
  rescue => error
    Rails.logger.error(
      "[SlackReservationError] action=open_modal slack_user_id=#{params[:user_id]} " \
      "error=#{error.class}: #{error.message}"
    )
    Honeybadger.notify(error) if defined?(Honeybadger)
    render json: {
      response_type: "ephemeral",
      text: "The reservation form could not be opened. Please try again or use the Member Portal."
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
