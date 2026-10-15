# Public resolution only: creation remains authenticated in ShortcodesController.
class ShortcodeResolutionsController < ActionController::Base
  before_action { response.set_header("Cache-Control", "no-store") }

  def show
    origin = ShortUrl.base_url(fallback_host: request.host_with_port)
    target = ShortUrl.resolve(params[:code], origin: origin)
    return render(json: { error: "Not Found" }, status: :not_found) unless target

    # Resolve cached mappings too, but never expose a disabled/deleted resource.
    ShortUrl.visible!(target)
    render json: { target_path: URI.parse(target).path }
  rescue PublicCatalog::Unavailable, ShortUrl::InvalidTarget
    render json: { error: "Not Found" }, status: :not_found
  rescue ShortUrl::Unavailable
    render json: { error: "Short URL unavailable" }, status: :service_unavailable
  end
end
