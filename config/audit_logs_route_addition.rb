# Add this inside the `namespace :admin` block, alongside the other admin resources:
#
#   resources :audit_logs, only: [:index]
#
# Example placement in config/routes.rb:
#
#   namespace :admin do
#     ...
#     resources :audit_logs, only: [:index]
#     ...
#   end
