class Slack::FixController < Slack::CommandsController
  skip_after_action :send_messages
  def command
    member = FixSlack.member!(params.to_unsafe_h)
    shop = FixSlack.channel_shop(member, params.to_unsafe_h)
    view = FixSlack.command_view(member, params[:text].to_s.strip, shop: shop)
    return render json: view if view[:response_type] == 'ephemeral'
    Service::SlackConnector.open_modal(params[:trigger_id], view)
    render json: { response_type: 'ephemeral', text: 'Opening Fix tickets…' }
  rescue Error::CustomError => error
    render json: { response_type: 'ephemeral', text: error.message }
  end
  private
  def verify_slack_signature
    return render(json: { error: 'Slack signing secret is not configured' }, status: :forbidden) if ENV['SLACK_SIGNING_SECRET'].blank?
    super
  end
end
