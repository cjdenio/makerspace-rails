# GET /api/config
#
# Public endpoint — no authentication required.
# Returns runtime configuration needed by the React client before login,
# including public integration URLs. Serves values from environment variables
# so deployment-specific values never need to be compiled into the JS bundle.
#
# Note that the firebase_api_key and the other firebase_ values are NOT secret.
#
# Also FIREBASE_AUTH_DOMAIN (authDomain) can only be a single string, not a list
#
class ClientConfigController < ApplicationController
  def index
    firebase_project_id = ENV["FIREBASE_PROJECT_ID"].to_s
    firebase_auth_domain =
      ENV["FIREBASE_AUTH_DOMAIN"].presence ||
      "#{firebase_project_id}.firebaseapp.com"
    firebase_auth_type =
      ENV["FIREBASE_AUTH_TYPE"].presence || "signInWithPopup"

    config = {
      firebase_api_key: ENV["FIREBASE_API_KEY"].to_s,
      firebase_project_id: firebase_project_id,
      firebase_auth_domain: firebase_auth_domain,
      firebase_auth_type: firebase_auth_type,
      wiki_url: WikiUrlBuilder.base_url
    }

    turnstile_site_key = ENV["TURNSTILE_SITE_KEY"].to_s.strip
    config[:turnstile_site_key] = turnstile_site_key if turnstile_site_key.present?

    render json: config, status: :ok
  end
end
