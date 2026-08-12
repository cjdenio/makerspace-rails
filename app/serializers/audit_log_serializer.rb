class AuditLogSerializer < ApplicationSerializer
  attributes :id,
             :log_type,
             :event_type,
             :actor_id,
             :actor_name,
             :subject_id,
             :subject_name,
             :resource_type,
             :resource_id,
             :field_changes,
             :before_snapshot,
             :after_snapshot,
             :slack_channel,
             :slack_message,
             :slack_posted,
             :ip_address,
             :created_at
end
