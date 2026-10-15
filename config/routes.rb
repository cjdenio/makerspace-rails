Rails.application.routes.draw do

  unless Rails.env.production?
    mount Rswag::Ui::Engine => '/api-docs'
    mount Rswag::Api::Engine => '/api-docs'
  end

  # Singular public URLs are also the targets encoded in printed QR codes.
  %w[shop tool].each do |kind|
    get "/#{kind}/:id/public", to: "public_catalog##{kind}", defaults: { format: :html }
    get "/api/#{kind}/:id/public", to: "public_catalog##{kind}", defaults: { format: :html }
  end
  get "/shops/:id/public", to: "public_catalog#shop", defaults: { format: :json }
  get "/tools/:id/public", to: "public_catalog#tool", defaults: { format: :json }
  get "/tools/:id/request-checkout", to: "checkout_links#show"
  # Where an approver lands from the public tool page: sign in, then check a member out on this tool.
  get "/tools/:id/check-out-member", to: "checkout_links#show"
  get "/api/tools/:id/coreq", to: "checkout_links#context"

  root to: "application#application"
  post '/ipnlistener', to: 'paypal#notify'
  post '/mailtrap_listener', to: 'mailtrap#webhooks', defaults: { format: :json }

  namespace :billing do
    post '/braintree_listener', to: 'braintree#webhooks'
  end

  # Slack inbound slash commands (outside :api scope — Slack posts form-encoded)
  namespace :slack do
    post '/events',             to: 'events#create'
    post '/commands/checkout',  to: 'commands#checkout'
    post '/commands/fix', to: 'fix#command'
    post '/commands/reserve',   to: 'commands#reserve'
    post '/commands/volunteer', to: 'commands#volunteer'
    post '/interactions',       to: 'interactions#create'
  end

  # Public volunteer pages — unauthenticated, token gated via SystemConfig
  namespace :volunteer do
    get '/bounties',     to: 'bounties#index'
    get '/leaderboard',  to: 'leaderboard#index'
  end

  get '/reservations/agenda', to: 'reservation_agendas#index'

  scope :api, defaults: { format: :json } do
    get "/shortcodes/:code", to: "shortcode_resolutions#show"
    post "/shortcodes", to: "shortcodes#create"
    devise_for :members, skip: [:registrations], controllers: { sessions: "sessions" }
    devise_scope :member do
       post "members", to: "registrations#create"
       post '/send_registration', to: 'registrations#new'
    end
    get '/signup_status', to: 'registrations#status'
    get '/invoice_options/signup', to: 'invoice_options#signup'
    resources :invoice_options, only: [:index, :show]
    resources :client_error_handler, only: [:create]

    # Public shop/tool listing
    resources :shops, only: [:index]
    resources :tools, only: [:index]
    post '/shops/:id/checkout_required_sheet', to: 'checkout_required_sheets#create', defaults: { kind: 'shop' }
    post '/tools/:id/checkout_required_sheet', to: 'checkout_required_sheets#create', defaults: { kind: 'tool' }
    resources :locations, only: [:index]

    # Public rental spot info — unauthenticated deep-link/QR landing
    get '/rental_spots/:id/public', to: 'rental_spots#public_show'

    namespace :billing do
      resources :plans, only: [:index]
      resources :discounts, only: [:index]
    end

    # Public runtime config — serves env vars to React client at runtime
    get '/config', to: 'client_config#index'
    get '/home', to: 'home#show'

    # Firebase authentication — public endpoints (no Devise session required)
    scope :auth do
      post   '/firebase_login',             to: 'firebase_auth#login'
      delete '/firebase_unlink/:member_id', to: 'firebase_auth#unlink'
    end

    authenticate :member do
      put "/members/change_password", to: "members/passwords#update"

      # TOTP self-service
      scope :members do
        post   '/totp/setup',   to: 'members/totp#setup'
        post   '/totp/verify',  to: 'members/totp#verify'
        delete '/totp',         to: 'members/totp#destroy'
        post   '/totp_sessions', to: 'members/totp_sessions#create'
      end
      resources :members, only: [:show, :index, :update] do
        scope module: :members do
          resources :permissions, only: [:index]
        end
      end

      # Member sees their own checkouts
      resources :tool_checkouts, only: [:index]
      resources :fix_tickets, only: [:index, :show, :create, :update] do
        collection { get :catalog }
        member do
          post :notes
          post :withdraw
          post :assignments
          get :assignee_options
          post :bounty
          post :reward
          post :reveal
          post :retry_delivery
          post :outage
        end
      end
      get '/volunteer/tasks/:id/detail', to: 'fix_bounties#show'
      post '/tools/:id/outage', to: 'tool_availability#create'
      post '/shops/:id/outage', to: 'shop_availability#create'
      resources :workshops, only: [:index]
      resources :tool_checkout_requests, only: [:index, :create, :update, :destroy]
      resources :tool_groups, only: [:index, :show, :create, :update, :destroy] do
        member do
          get :review
          post :approve
          post :volunteer
          get :volunteers
          post :decide_volunteer
        end
      end
      resources :reservation_catalog, only: [:index]
      resources :reservations, only: [:index, :create, :update, :destroy] do
        collection do
          get :availability
          get :blackouts
          post :preview
        end
        member do
          post :preview, action: :preview_update
        end
      end

      # Rentals — member self-service
      resources :rentals, only: [:show, :index, :update, :create] do
        member do
          delete :cancel
          delete :decline_agreement
          post   :mark_vacated
        end
      end

      # Rental spots — member browse
      resources :rental_spots, only: [:index, :show]

      # Rental types — member dropdown
      resources :rental_types, only: [:index]

      resources :invoices, only: [:index, :create]
      resources :documents, only: [:show], defaults: { format: :html }

      namespace :billing do
        resources :payment_methods, only: [:new, :create, :show, :index, :destroy] do
          member do
            get :cancellation_impact
          end
        end
        resources :subscriptions, only: [:show, :update, :destroy] do
          member do
            get :cancellation_impact
          end
        end
        resources :transactions, only: [:create, :index, :destroy]
        resources :receipts, only: [:show], defaults: { format: :html }
      end

      resources :earned_memberships, only: [:show] do
        scope module: :earned_memberships do
          resources :reports, only: [:index, :create]
        end
      end

      # Volunteer — member self-service
      get    '/volunteer/credits',            to: 'volunteer#credits'
      get    '/volunteer/summary',            to: 'volunteer#summary'
      get    '/volunteer/tasks',              to: 'volunteer#tasks'
      get    '/volunteer/tasks/my_claims',    to: 'volunteer#my_claims'
      get    '/volunteer/events',             to: 'volunteer#events'
      post   '/volunteer/tasks/:id/claim',    to: 'volunteer#claim_task'
      post   '/volunteer/tasks/:id/complete', to: 'volunteer#complete_task'
      post   '/volunteer/events/:id/checkin', to: 'volunteer#checkin_event'
      delete '/volunteer/events/:id/checkin', to: 'volunteer#remove_checkin'

      namespace :admin do
        resources :cards, only: [:new, :create, :index, :update, :destroy] do
          get :lookup, on: :collection
        end
        resources :checkins, only: [:index]
        resources :rejections, only: [:index]
        resources :audit_logs, only: [:index]
        resources :invoices, only: [:index, :create, :update, :destroy] do
          member do
            post :force_cancel
          end
        end
        resources :invoice_options, only: [:create, :update, :destroy]

        # Tool checkout management
        resources :shops, only: [:index, :create, :update, :destroy] do
          get :resource_manager_options, on: :collection
          member do
            patch :requestor_annotation
          end
        end
        get 'google_calendar/colors', to: 'google_calendar#colors'
        resources :tools, only: [:index, :create, :update, :destroy] do
          member do
            patch :notes
            patch :requestor_annotation
          end
        end
        resources :locations, only: [:index, :create, :update, :destroy]
        resources :tool_checkouts, only: [:index, :create, :destroy] do
          post :lookup_card, on: :collection
        end
        resources :tool_checkout_requests, only: [:index] do
          member do
            post :decline
          end
        end
        resources :checkout_approvers, only: [:index, :create, :update, :destroy]
        resources :reservations, only: [:index, :create, :update, :destroy] do
          collection do
            post :preview, action: :preview_create
          end
          member do
            post :preview
            post :approve
            post :deny
          end
        end
        resources :reservation_blackouts, only: [:index, :create, :update, :destroy]

        # Rentals — admin manage + approve/deny
        resources :rentals, only: [:create, :update, :destroy, :index] do
          member do
            post :approve
            post :deny
          end
        end

        # Rental spots catalog — admin CRUD
        resources :rental_spots, only: [:index, :create, :update, :destroy]

        # Rental types — admin CRUD
        resources :rental_types, only: [:index, :create, :update, :destroy]

        resources :members, only: [:create, :update] do
          member do
            post :update_password
            post :send_password_reset
            post :invite_slack
            post :invite_google_drive
            post :soft_delete
            post :restore
            get  'mailtrap_events', to: 'members/mailtrap_events#index'
          end
        end

        # Admin TOTP reset
        namespace :members do
          delete '/:member_id/totp', to: 'totp#destroy'
        end
        resources :groups, only: [:index, :show, :create, :destroy] do
          member do
            post :add_member
            delete :remove_member
          end
          collection do
            get :for_member
          end
        end
        resources :permissions, only: [:index, :update]
        resources :analytics, only: [:index] do
          collection do
            get :member_growth
            get :member_losses
            get :active_members
            get :volunteer_summary
          end
        end

        resources :space_usage, only: [:index] do
          collection do
            get :date_range
          end
        end

        # Space usage — unique member checkins per day/month
        get '/space_usage',            to: 'space_usage#index'
        get '/space_usage/date_range', to: 'space_usage#date_range'

        # Member Portal Settings
        resources :system_configs, only: [:index] do
          collection do
            put  :update_flag
            put  :update_setting
            post :run_job
          end
        end

        resources :slack_identity_conflicts, only: [:index] do
          collection do
            post :reassign
            post :dismiss
          end
        end
        resources :templates, only: [:index] do
          member do
            post :refresh
            post :restore
            post :populate
          end
        end

        namespace :billing do
          resources :subscriptions, only: [:index, :destroy] do
            member do
              get :cancellation_impact
            end
          end
          resources :transactions, only: [:show, :index, :destroy]
          resources :receipts, only: [:show], defaults: { format: :html }
        end

        resources :earned_memberships, only: [:index, :show, :create, :update] do
          member do
            post :suspend
            post :reactivate
          end
          scope module: :earned_memberships do
            resources :reports, only: [:index]
          end
        end

        # Volunteer credits — admin/RM manage
        resources :volunteer_credits, only: [:index, :create, :destroy] do
          member do
            post :approve
            post :reject
            post :reverse
          end
        end

        # Volunteer bounty tasks — admin/RM manage
        resources :volunteer_tasks, only: [:index, :create, :update, :destroy] do
          member do
            post :complete
            post :cancel
            post :release
            post :reject_pending
            post :reset_cooldown
          end
        end

        # Volunteer events — admin/RM manage
        resources :volunteer_events, only: [:index, :create, :show, :update, :destroy] do
          member do
            post   :close
            post   :add_attendee
            delete :remove_attendee
          end
        end
      end
    end
  end

  get '/favicon.ico', to: proc { [204, {}, []] }
  get '*path', to: 'application#application'
end
