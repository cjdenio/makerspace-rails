class ToolCheckoutRequestsController < AuthenticationController
  include CatalogUnavailable
  prepend_before_action { response.set_header("Cache-Control", "private, no-store") }

  before_action :find_request, only: [:update, :destroy]

  def index
    requests = CheckoutInteractionQuery.new(member: current_member).open_requests
    if params[:include_groups] == 'true'
      requests = requests.to_a + CheckoutInteractionQuery.new(member: current_member).visible_group_requests.select { |request| request.member_id == current_member.id }
    end

    requests = ToolCheckoutRequest.table_query(requests, params)
    response.set_header("total-items", requests.count)

    render json: requests,
      each_serializer: ToolCheckoutRequestSerializer,
      adapter: :attributes
  end

  def create
    if request_params[:tool_group_id].present?
      raise Error::UnprocessableEntity.new('Choose exactly one tool or group') if request_params[:tool_id].present?
      group = ToolGroup.find(request_params[:tool_group_id]) || raise(Error::NotFound.new)
      request = ToolGroupCheckout.request!(member: current_member, group: group, note: request_params[:note])
      return render json: request, serializer: ToolCheckoutRequestSerializer, adapter: :attributes
    end
    tool, = PublicCatalog.tool(request_params[:tool_id], public_only: false)
    request = CheckoutRequestCreation.create!(member_id: current_member.id, tool_id: tool.id,
      shop_id: tool.shop_id, note: request_params[:note])

    render json: request, serializer: ToolCheckoutRequestSerializer, adapter: :attributes
  end

  def update
    mutate_request! { @request.update_attributes!(request_params.slice(:note)) }
    render json: @request, serializer: ToolCheckoutRequestSerializer, adapter: :attributes
  end

  def destroy
    mutate_request! { @request.update_attributes!(status: "deleted") }
    CheckoutCreation.notify { @request.remove_announcement }
    render json: {}, status: 204
  end

  private

  def mutate_request!
    mutation = proc do
      @request.reload
      raise Error::Forbidden.new unless @request.member_id == current_member.id && @request.open?
      tool = @request.target
      raise Error::Forbidden.new unless tool && !tool.disabled? && tool.shop && !tool.shop.disabled?
      yield
    end
    if @request.tool_group_id
      ToolGroupCheckout.with_request_locks(@request, &mutation)
    else
      CatalogMutationLock.with([@request.target&.shop_id]) do
        CheckoutMutationLock.with(member_id: @request.member_id, tool_id: @request.tool_id, &mutation)
      end
    end
  end

  def request_params
    params.permit(:tool_id, :tool_group_id, :note)
  end

  def find_request
    @request = ToolCheckoutRequest.find(params[:id])
    raise Error::NotFound.new unless @request
  end

end
