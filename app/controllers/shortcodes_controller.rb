class ShortcodesController < AuthenticationController
  include CatalogUnavailable
  prepend_before_action { response.set_header("Cache-Control", "private, no-store") }

  def create
    origin = ShortUrl.base_url(fallback_host: request.host_with_port)
    target = ShortUrl.normalize(params[:target_url], origin: origin)
    ShortUrl.visible!(target)
    render json: ShortUrl.allocate(target, origin: origin)
  rescue ShortUrl::InvalidTarget
    render json: { error: "Unsupported target URL" }, status: :unprocessable_entity
  rescue ShortUrl::Unavailable
    render json: { error: "Short URL unavailable" }, status: :service_unavailable
  end
end
