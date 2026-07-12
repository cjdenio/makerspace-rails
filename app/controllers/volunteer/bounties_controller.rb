class Volunteer::BountiesController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :authenticate_member! rescue nil
  skip_after_action  :send_messages

  before_action :check_token

  def index
    if request.format.json?
      render plain: active_tasks_json.to_json, content_type: 'application/json' and return
    end
    @tasks = VolunteerTask.claimable.where(parent_task_id: nil).order_by(task_number: :asc)
    render 'volunteer/bounties/index', layout: false
  end

  private

  def check_token
    token_enabled = (SystemConfig.get('volunteer_bounty_token_enabled') ||
                     ENV.fetch('VOLUNTEER_BOUNTY_TOKEN_ENABLED', 'false')) == 'true'
    return unless token_enabled
    expected_token = SystemConfig.get('volunteer_bounty_token') ||
                     ENV.fetch('VOLUNTEER_BOUNTY_TOKEN', '')
    provided_token = params[:token].to_s
    unless expected_token.present? && ActiveSupport::SecurityUtils.secure_compare(provided_token, expected_token)
      if request.format.json?
        render plain: { error: 'Access denied.' }.to_json, content_type: 'application/json', status: :forbidden
      else
        render plain: 'Access denied.', status: :forbidden
      end
    end
  end

  def active_tasks_json
    # Show parent-level claimable tasks only; exclude cooling-down recurring tasks
    # and child documents spawned from multi-use claims.
    VolunteerTask.claimable.where(parent_task_id: nil).order_by(task_number: :asc).map do |t|
      {
        id:           t.id.to_s,
        task_number:  t.task_number,
        title:        t.title,
        description:  t.description,
        credit_value: t.credit_value,
        status:       t.status,
        shop_name:    (t.shop&.name rescue nil),
        claimed_at:   t.claimed_at,
        next_available: t.next_available
      }
    end
  end
end
