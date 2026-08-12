class Admin::TemplatesController < AdminController
  before_action :require_admin!

  # GET /api/admin/templates
  def index
    render json: { templates: Service::EmailTemplate.statuses }, status: :ok
  end

  # POST /api/admin/templates/:id/refresh
  def refresh
    perform_action!(:refresh) { Service::EmailTemplate.refresh!(template_name) }
  end

  # POST /api/admin/templates/:id/restore
  def restore
    perform_action!(:restore) { Service::EmailTemplate.restore_default!(template_name) }
  end

  # POST /api/admin/templates/:id/populate
  def populate
    perform_action!(:populate) { Service::EmailTemplate.populate!(template_name) }
  end

  private

  def require_admin!
    raise ::Error::Forbidden.new unless is_admin?
  end

  def template_name
    name = params[:id].to_s.to_sym
    raise KeyError, "Unknown template: #{params[:id]}" unless Service::EmailTemplate::TEMPLATE_ENV_KEYS.key?(name)
    name
  end

  def perform_action!(action)
    before = Service::EmailTemplate.status(template_name)
    yield
    after = Service::EmailTemplate.status(template_name)
    audit!(action, before, after)
    render json: { template: after }, status: :ok
  rescue KeyError => error
    render json: { error: error.message }, status: :not_found
  rescue Service::EmailTemplate::PermissionError => error
    audit_failure!(action, error)
    render json: { error: "Google denied permission: #{error.message}" }, status: :forbidden
  rescue Service::EmailTemplate::MissingEnvironmentVariable,
         Service::EmailTemplate::InvalidTemplate,
         Service::EmailTemplate::TemplateError => error
    audit_failure!(action, error)
    render json: { error: error.message }, status: :unprocessable_entity
  end

  def audit!(action, before, after)
    Service::AuditLogger.log(
      log_type: 'portal',
      event_type: "template_#{action}",
      resource_type: 'ExternalTemplate',
      resource_id: BSON::ObjectId.new,
      actor: current_member,
      field_changes: {
        after[:env_key] => [before[:status], after[:status]],
        'fetched_at' => [before[:fetched_at], after[:fetched_at]]
      },
      message_details: "#{action.to_s.titleize} #{after[:env_key]}",
      slack_channel: ::Service::SlackConnector.logs_channel
    )
  end

  def audit_failure!(action, error)
    Service::AuditLogger.log(
      log_type: 'portal',
      event_type: 'template_action_failed',
      resource_type: 'ExternalTemplate',
      resource_id: BSON::ObjectId.new,
      actor: current_member,
      field_changes: { 'action' => [nil, action.to_s] },
      message_details: "#{Service::EmailTemplate::TEMPLATE_ENV_KEYS[template_name]}: #{error.message}",
      slack_channel: ::Service::SlackConnector.logs_channel
    )
  rescue => audit_error
    Honeybadger.notify(audit_error) if defined?(Honeybadger)
  end
end
