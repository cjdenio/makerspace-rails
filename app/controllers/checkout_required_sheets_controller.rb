class CheckoutRequiredSheetsController < AuthenticationController
  prepend_before_action { response.set_header('Cache-Control', 'private, no-store') }

  def create
    kind = request.path_parameters[:kind]
    return unavailable unless BSON::ObjectId.legal?(params[:id].to_s)

    resource = (kind == 'shop' ? Shop : Tool).where(id: params[:id]).first
    return unavailable unless resource
    shop = kind == 'shop' ? resource : resource.shop
    return unavailable unless shop
    return unavailable if shop.disabled? || resource.disabled?

    policy = CheckoutRequiredSheetPolicy.new(current_member,
      approver: CheckoutApprover.find_by(member_id: current_member.id))
    raise Error::Forbidden.new('You cannot generate a sheet for this resource') unless policy.authorized?(resource, shop: shop)
    if kind == 'tool' && resource.open
      return render json: { error: 'This tool does not require checkout. A Checkout Required sheet cannot be generated.' }, status: :unprocessable_entity
    end

    copies = params.fetch(:copies, 2).to_s
    unless %w[1 2].include?(copies)
      return render json: { error: 'Choose one or two signs per sheet.' }, status: :unprocessable_entity
    end

    origin = ShortUrl.base_url(fallback_host: request.host_with_port)
    short_url = ShortUrl.allocate("/api/#{kind}/#{resource.id}/public.html", origin: origin)[:short_url]
    sheet = CheckoutRequiredSheet.new(name: resource.name, channel: shop.slack_channel, short_url: short_url, copies: copies.to_i)
    response.set_header('X-Checkout-Sheet-Warning', 'missing_shop_channel') if sheet.channel.empty?
    send_data sheet.to_svg, type: 'image/svg+xml', disposition: 'attachment',
      filename: "checkout-required-#{kind}-#{resource.id}.svg"
  rescue ShortUrl::Unavailable, ShortUrl::InvalidTarget
    render json: { error: 'The short link is unavailable. Please try again.' }, status: :service_unavailable
  end

  private

  def unavailable
    render json: { error: 'This shop or tool is missing or hidden. A sheet cannot be generated.' }, status: :not_found
  end
end
