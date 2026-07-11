# GET /api/config
#
# Public endpoint — no authentication required.
# Returns runtime configuration needed by the React client before login.
# Serves values from environment variables so secrets never touch git or the
# built JS bundle.
#
class ClientConfigController < ApplicationController
  def index
    render json: {
      firebase_api_key:    ENV['FIREBASE_API_KEY'].to_s,
      firebase_project_id: ENV['FIREBASE_PROJECT_ID'].to_s,
    }, status: :ok
  end
end
