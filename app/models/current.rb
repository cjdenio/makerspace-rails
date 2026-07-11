# A model that is used to track properties without drilling them through fns
class Current < ActiveSupport::CurrentAttributes
    attribute :request_id, :user_agent, :ip_address, :url, :method, :params
    # Set in controllers before any write action so AuditLog can read the actor
    # without requiring it to be threaded through every method signature.
    attribute :actor
end
