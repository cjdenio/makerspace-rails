class CheckoutLinksController < ApplicationController
  include CatalogUnavailable
  prepend_before_action :private_response
  before_action :require_member
  before_action :visible_tool

  def show
    render "layouts/application"
  end

  # The .html URL is a small JSON context endpoint consumed by the React form.
  def context
    tool = @tool
    reason = tool.checkout_request_error(current_member)
    render json: { tool: ActiveModelSerializers::SerializableResource.new(tool, serializer: ToolCatalogSerializer, adapter: :attributes, scope: current_member).as_json,
                   eligible: reason.nil?, reason: reason }
  end

  private

  def private_response
    response.set_header("Cache-Control", "private, no-store")
  end

  def require_member
    return if member_signed_in? && session[:totp_pending_member_id].blank?
    if action_name == "show"
      redirect_to "/login?return_to=#{ERB::Util.url_encode(request.path)}"
    else
      render json: { error: "Authentication required" }, status: :unauthorized
    end
  end

  def visible_tool
    @tool, = PublicCatalog.tool(params[:id], public_only: false)
  end
end
