class ToolCheckoutRequestsController < AuthenticationController
  before_action :find_request, only: [:update, :destroy]

  def index
    requests = ToolCheckoutRequest.where(member_id: current_member.id, status: "open")
    visible_tool_ids = Tool.where(:disabled.ne => true).pluck(:id)
    requests = requests.where(:tool_id.in => visible_tool_ids)

    requests = ToolCheckoutRequest.table_query(requests, params)
    response.set_header("total-items", requests.count)

    render json: requests,
      each_serializer: ToolCheckoutRequestSerializer,
      adapter: :attributes
  end

  def create
    tool = Tool.find(request_params[:tool_id])
    eligible = if current_member.status == 'pending'
      tool.allow_pending
    else
      current_member.active_unexpired? && current_member.status == 'activeMember'
    end
    unless eligible
      raise ::Error::Forbidden.new(
        "Your membership must first be activated and you must complete your Orientation checkout before requesting this Safety Checkout"
      )
    end
    raise ::Error::Forbidden.new if tool.disabled?
    raise ::Error::UnprocessableEntity.new("A checkout record already exists for this tool") if ToolCheckout.where(member_id: current_member.id, tool_id: tool.id).exists?
    raise ::Error::UnprocessableEntity.new("An open request already exists for this tool") if ToolCheckoutRequest.where(member_id: current_member.id, tool_id: tool.id, status: "open").exists?

    request = ToolCheckoutRequest.create!(
      member_id: current_member.id,
      tool_id: tool.id,
      note: request_params[:note],
      request_date: Time.now,
      status: "open"
    )
    request.announce_request

    render json: request, serializer: ToolCheckoutRequestSerializer, adapter: :attributes
  end

  def update
    raise ::Error::Forbidden.new unless @request.member_id.to_s == current_member.id.to_s && @request.open?
    raise ::Error::Forbidden.new if @request.tool.try(:disabled?)

    @request.update_attributes!(request_params.slice(:note))
    render json: @request, serializer: ToolCheckoutRequestSerializer, adapter: :attributes
  end

  def destroy
    raise ::Error::Forbidden.new unless @request.member_id.to_s == current_member.id.to_s && @request.open?
    raise ::Error::Forbidden.new if @request.tool.try(:disabled?)

    @request.remove_announcement
    @request.update_attributes!(status: "deleted")
    render json: {}, status: 204
  end

  private

  def request_params
    params.permit(:tool_id, :note)
  end

  def find_request
    @request = ToolCheckoutRequest.find(params[:id])
  end

end
