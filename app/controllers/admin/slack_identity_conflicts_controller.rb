class Admin::SlackIdentityConflictsController < AdminController
  # GET /api/admin/slack_identity_conflicts
  def index
    render json: { conflicts: Service::SlackUserSync.detect_conflicts }
  end

  # POST /api/admin/slack_identity_conflicts/reassign
  def reassign
    params.require([:slack_id, :member_id])
    member = Service::SlackUserSync.reassign_identity(
      slack_id: params[:slack_id],
      member_id: params[:member_id],
      actor: current_member
    )
    render json: { message: "#{params[:slack_id]} linked to #{member.fullname}", member_id: member.id.to_s }, status: :ok
  end

  # POST /api/admin/slack_identity_conflicts/dismiss
  def dismiss
    params.require([:slack_id, :member_id])
    member = Service::SlackUserSync.dismiss_conflict(
      slack_id: params[:slack_id],
      member_id: params[:member_id],
      slack_email: params[:slack_email],
      slack_name: params[:slack_name],
      actor: current_member
    )
    render json: { message: "#{params[:slack_id]} dismissed for #{member.fullname}", member_id: member.id.to_s }, status: :ok
  end
end
