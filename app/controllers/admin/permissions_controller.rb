class Admin::PermissionsController < AdminController
  before_action :find_member, only: [:update]

  def index
    permissions = Permission.list_permissions
    render json: permissions, adapter: :attributes and return
  end

  def update
    before = @member.get_permissions
    @member.update_permissions(update_params)
    @member.reload

    ::Service::AuditLogger.log(
      log_type:        'member',
      event_type:      'permissions_updated',
      resource_type:   'Member',
      resource_id:     @member.id,
      actor:           current_member,
      subject:         @member,
      before_snapshot: { permissions: before },
      after_snapshot:  { permissions: @member.get_permissions },
      slack_channel:   ::Service::SlackConnector.logs_channel
    )

    render json: @member, adapter: :attributes and return
  end

  private
  def update_params
    params.require(:member).permit(permissions: {})
  end

  def find_member
    @member = Member.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: params[:id] }) if @member.nil?
  end
end

# TODO: IS THIS NOT USED??