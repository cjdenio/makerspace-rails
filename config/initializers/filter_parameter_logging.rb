# Be sure to restart your server when you modify this file.

# Configure sensitive parameters which will be filtered from the log file.
Rails.application.config.filter_parameters += [
  :reporter_id, :actor_id, :member_ids, :assignee_ids, :note, :description,
  :announcement_note, :private_metadata, :response_url,
  :payload, # Slack's JSON string can contain a nested response URL.
  :password,
  :password_confirmation,
  :secret,
  :secret_key_base,
  :token,
  :api_key,
  :client_secret,
  :private_key,
  :otp_secret,
  :otp_secret_encrypted,
  :bt_signature,
  :bt_payload
]
