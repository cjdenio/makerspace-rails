class ApplicationController < ActionController::Base
  include ApplicationHelper
  include ::Error::ErrorHandler
  include SlackService
  include SetCurrentRequestDetails
  include ActionView::Helpers::SanitizeHelper

  protect_from_forgery with: :exception
  after_action :set_csrf_cookie_for_ng
  after_action :log_not_found_file_lookup_context, if: -> { response.status == 404 }
  before_action :configure_permitted_parameters, if: :devise_controller?
  before_action :filter_requests
  before_action :require_completed_totp_challenge
  before_action :allow_only_html_requests, only: [:application]

  def application
    render "layouts/application"
  end

  def set_csrf_cookie_for_ng
    cookies['XSRF-TOKEN'] = form_authenticity_token if protect_against_forgery?
  end

  protected

  def log_not_found_file_lookup_context
    return if @logged_not_found_file_lookup_context

    @logged_not_found_file_lookup_context = true
    Rails.logger.info(
      "[404 file lookup] requested_path=#{request.path} " \
      "translated_locations=#{translated_file_lookup_locations.join(', ')}"
    )
  rescue => e
    Rails.logger.warn("Failed to log 404 file lookup context: #{e.message}")
  end

  def translated_file_lookup_locations
    requested_path = request.path.to_s
    relative_path = requested_path.delete_prefix('/')
    clean_relative_path = Pathname.new(relative_path).cleanpath.to_s
    clean_relative_path = '' if clean_relative_path.start_with?('..')

    lookup_roots = [Rails.root.join('public')]
    if Rails.application.config.respond_to?(:assets)
      lookup_roots += Array(Rails.application.config.assets.paths)
    end

    lookup_roots.map do |root|
      clean_relative_path.present? ? File.join(root.to_s, clean_relative_path) : root.to_s
    end.uniq
  end

  def allow_only_html_requests
    if params[:format] && params[:format] != "html"
      Rails.logger.info("[allow_only_html] #{scrub_log_value(params[:format])}.")
      render plain: "Not Found", status: 404
    end
  end

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [:firstname, :lastname])
  end

  # In Rails 4.2 and above
  def verified_request?
    super || valid_authenticity_token?(session, request.headers['X-XSRF-TOKEN'])
  end

  def is_admin?
    current_member.try(:role) == 'admin'
  end

  def is_resource_manager?
    current_member.try(:role) == 'resource_manager'
  end

  def is_board_member?
    current_member.try(:role) == 'board_member'
  end

  def is_privileged?
    is_admin? || is_board_member? || is_resource_manager?
  end

  def is_valid_checkout_approver?
    current_member.try(:valid_for_checkout_request?) && CheckoutApprover.exists?(member_id: current_member.id)
  end

  def can_view_disabled_tools?
    is_admin? || is_board_member? || is_resource_manager?
  end

  def filter_requests
    if params[:format] && (/js|png|svg|txt|html|json/ =~ params[:format]).nil?
      Rails.logger.info("[filter_requests] #{scrub_log_value(params[:format])}.")
      raise Error::NotFound.new
    end
  end

  def scrub_log_value(value)
    return value unless value.is_a?(String)

    sanitize(normalize_log_value(value))
  end

  def normalize_log_value(value)
    normalized_value = value.dup
    normalized_value.force_encoding(Encoding::UTF_8) if normalized_value.encoding == Encoding::ASCII_8BIT
    normalized_value = normalized_value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
    normalized_value.unicode_normalize
  rescue Encoding::CompatibilityError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
    value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '').unicode_normalize
  end

  def require_completed_totp_challenge
    return unless request.path.start_with?('/api/')
    return unless member_signed_in? && session[:totp_pending_member_id].present?

    expire_stale_totp_challenge
    return unless member_signed_in? && session[:totp_pending_member_id].present?
    return if totp_challenge_exempt_request?

    render json: { error: 'TOTP verification required.' }, status: :unauthorized
  end

  def expire_stale_totp_challenge
    expires_at = session[:totp_pending_expires_at].to_i
    return if expires_at.zero? || Time.now.to_i <= expires_at

    session.delete(:totp_pending_member_id)
    session.delete(:totp_pending_expires_at)
    sign_out(:member)
  end

  def totp_challenge_exempt_request?
    return true if controller_path == 'members/totp_sessions' && action_name == 'create'
    return true if controller_path == 'client_config' && action_name == 'index'

    false
  end
end
