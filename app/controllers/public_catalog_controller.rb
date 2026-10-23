# No ApplicationController callbacks, authentication, session, or CSRF helpers.
class PublicCatalogController < ActionController::Base
  include CatalogUnavailable
  TEMPLATE_VERSION = "public-catalog-v8-approver-checkout-link"

  def shop
    shop = PublicCatalog.shop(params[:id])
    return serve_qr(shop, "shop") if request.format.svg?
    tools = Tool.where(shop_id: shop.id, :disabled.ne => true)
      .only(:id, :name, :open, :out_of_service).collation(locale: "en", strength: 2).order_by(name: :asc, id: :asc)
    projection = PublicCatalog.shop_fields(shop).merge(tools: tools.map do |tool|
      { id: tool.id.to_s, name: tool.name, open: tool.open, out_of_service: !!tool.out_of_service }
    end)
    projection[:calendars] = [PublicCatalog.calendar_fields(shop)].compact if request.format.html?
    serve(projection, "shop")
  end

  def tool
    tool, shop = PublicCatalog.tool(params[:id])
    return serve_qr(tool, "tool") if request.format.svg?
    projection = PublicCatalog.tool_fields(tool, shop)
    if request.format.html?
      projection[:calendars] = [tool, shop].filter_map { |record| PublicCatalog.calendar_fields(record) }.uniq { |calendar| calendar[:url] }
      # Static map only (floor-plan geometry, no names); the public JSON
      # stays unchanged.
      projection[:map] = PublicCatalog.tool_map(tool, shop)
    end
    serve(projection, "tool")
  end

  # Keep API/SVG errors generic, while giving stale HTML links a useful directory.
  def catalog_unavailable
    return super unless request.format.html?

    response.headers.delete("ETag")
    response.headers.delete("Last-Modified")
    response.set_header("Cache-Control", "no-store")
    shops = Shop.where(:disabled.ne => true).only(:id, :name, :out_of_service)
      .collation(locale: "en", strength: 2).order_by(name: :asc, id: :asc)
    page = { name: "Workshops", title: "Workshops", footer_links: PublicCatalog.footer_links,
             shops: shops.map { |shop| { id: shop.id.to_s, name: shop.name, out_of_service: !!shop.out_of_service } } }
    render template: "public_catalog/workshops", layout: "public_catalog", locals: { page: page }, status: :not_found
  end

  private

  def serve_qr(record, kind)
    origin = ShortUrl.base_url(fallback_host: request.host_with_port)
    url = ShortUrl.allocate("/api/#{kind}/#{record.id}/public.html", origin: origin)[:short_url]
    digest = Digest::SHA256.hexdigest([TEMPLATE_VERSION, "qr", url].join("\n"))
    return unless fresh_public_response?(digest)

    svg = cached_render("public-qr/#{digest}") do
      mode = url.match?(/\A[0-9A-Z $%*+\-.\/:]+\z/) ? :alphanumeric : :byte_8bit
      RQRCode::QRCode.new(url, mode: mode).as_svg(
        color: "000", fill: "fff", module_size: 6, offset: 24,
        standalone: true, use_path: true, viewbox: true
      )
    end
    render body: svg, content_type: "image/svg+xml"
  rescue KeyError, URI::InvalidComponentError, ShortUrl::InvalidTarget, ShortUrl::Unavailable
    response.headers.delete("ETag")
    response.set_header("Cache-Control", "no-store")
    render plain: "Public URL unavailable", status: :service_unavailable
  end

  def fresh_public_response?(digest)
    response.set_header("Cache-Control", request.format.svg? ? "public, max-age=259200, s-maxage=259200" : "public, max-age=0, s-maxage=0, must-revalidate")
    response.set_header("ETag", %Q("#{digest}"))
    return true unless request.fresh?(response)

    head :not_modified
    false
  end

  def cached_render(key)
    Rails.cache.fetch(key, expires_in: 30.minutes) { yield }
  rescue StandardError => error
    Rails.logger.warn("Public catalog cache unavailable: #{error.class}")
    yield
  end

  def serve(projection, kind)
    raise PublicCatalog::Unavailable unless request.format.html? || request.format.json?
    projection[:footer_links] = PublicCatalog.footer_links if request.format.html?
    digest = Digest::SHA256.hexdigest([TEMPLATE_VERSION, kind, request.format.to_s, projection.to_json].join("\n"))
    return unless fresh_public_response?(digest)
    return render(json: projection) if request.format.json?

    html = cached_render("public-catalog/#{digest}") do
      render_to_string(template: "public_catalog/#{kind}", layout: "public_catalog", locals: { page: projection })
    end
    render html: html.html_safe, layout: false
  end
end
