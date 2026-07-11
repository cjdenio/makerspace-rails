# Be sure to restart your server when you modify this file.

# Configure sensitive parameters which will be filtered from the log file.
Rails.application.config.filter_parameters += [
  :password,
  :password_confirmation,
  :secret,
  :secret_key_base,
  :token,
  :api_key,
  :client_secret,
  :private_key,
  :otp_secret,
  :otp_secret_encrypted
]
