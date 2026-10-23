class HomeController < AuthenticationController
  prepend_before_action do
    response.set_header("Cache-Control", "private, no-store")
    # Keep expected authentication failures here, including Devise's timeout
    # throw, so they retain this header and never enter the alerting error handler.
    authenticated = catch(:warden) do
      expire_stale_totp_challenge if session[:totp_pending_member_id].present?
      member_signed_in?
    end
    unless authenticated == true
      error = Error::Unauthorized.new
      render json: Error::Helpers::Render.json(error.status, error.error, error.message), status: :unauthorized
    end
  end

  def show
    home = MemberHome.new(current_member)
    render json: {
      member: ActiveModelSerializers::SerializableResource.new(
        current_member, serializer: MemberSerializer, adapter: :attributes,
        resolve_slack_url: false
      ).as_json,
      slack: home.slack,
      availableCheckouts: home.available_checkouts,
      availableVolunteerOpportunities: home.available_volunteer_opportunities
    }
  end
end
