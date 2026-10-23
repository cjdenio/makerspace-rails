module CatalogUnavailable
  extend ActiveSupport::Concern
  included do
    rescue_from PublicCatalog::Unavailable, with: :catalog_unavailable
  end

  def set_csrf_cookie_for_ng
    super unless response.status == 404
  end

  def catalog_unavailable
    response.headers.delete("ETag")
    response.headers.delete("Last-Modified")
    response.set_header("Cache-Control", "no-store")
    render plain: "Not Found", status: :not_found
  end
end
