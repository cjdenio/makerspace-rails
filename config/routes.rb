Rails.application.routes.draw do

  unless Rails.env.production?
    mount Rswag::Ui::Engine => '/api-docs'
    mount Rswag::Api::Engine => '/api-docs'
  end

  root to: "application#application"
  post '/ipnlistener', to: 'paypal#notify'
  post '/mailtrap_listener', to: 'mailtrap#webhooks', defaults: { format: :json }

  namespace :billing do
    post '/braintree_listener', to: 'braintree#webhooks'
  end

  # Slack inbound slash commands (outside :api scope — Slack posts form-encoded)
  namespace :slack do
    post '/commands/checkout',  to: 'commands#checkout'
    post '/commands/volunteer', to: 'commands#volunteer'
  end

  # Public volunteer pages — unauthenticated, token gated via SystemConfig
  namespace :volunteer do
    get '/bounties',     to: 'bounties#index'
    get '/leaderboard',  to: 'leaderboard#index'
  end

  scope :api, defaults: { format: :json } do
    devise_for :members, skip: [:registrations], controllers: { sessions: "sessions" }
    devise_scope :member do
       post "members", to: "registrations#create"
       post '/send_registration', to: 'registrations#new'
    end
    resources :invoice_options, only: [:index, :show]
    resources :client_error_handler, only: [:create]

    # Public shop/tool listing
    resources :shops, only: [:index]
    resources :tools, only: [:index]

    # Public rental spot info — unauthenticated deep-link/QR landing
    get '/rental_spots/:id/public', to: 'rental_spots#public_show'

    namespace :billing do
      resources :plans, only: [:index]
      resources :discounts, only: [:index]
    end

    # Public runtime config — serves env vars to React client at runtime
    get '/config', to: 'client_config#index'

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
        resources :payment_methods, only: [:new, :create, :show, :index, :destroy]
        resources :subscriptions, only: [:show, :update, :destroy]
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
        resources :cards, only: [:new, :create, :index, :update]
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
        resources :shops, only: [:index, :create, :update, :destroy]
        resources :tools, only: [:index, :create, :update, :destroy]
        resources :tool_checkouts, only: [:index, :create, :destroy]
        resources :checkout_approvers, only: [:index, :create, :update, :destroy]

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

        namespace :billing do
          resources :subscriptions, only: [:index, :destroy]
          resources :transactions, only: [:show, :index, :destroy]
          resources :receipts, only: [:show], defaults: { format: :html }
        end

        resources :earned_memberships, only: [:index, :show, :create, :update] do
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
        resources :volunteer_events, only: [:index, :create, :show, :destroy] do
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
