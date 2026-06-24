Rails.application.configure do

  # Settings specified here will take precedence over those in config/application.rb.

  # In the development environment your application's code is reloaded on
  # every request. This slows down response time but is perfect for development
  # since you don't have to restart the web server when you make code changes.
  config.cache_classes = false
  config.hosts << "members.manchestermakerspace.com"
  config.hosts << "members.manchestermakerspace.org"
  config.hosts << "makerspace-dev-51ba804d4c30.herokuapp.com"
  # Do not eager load code on boot.
  config.eager_load = true

  # Show full error reports.
  config.consider_all_requests_local = true

  config.cache_store = :redis_cache_store, {
    url: ENV["REDIS_URL"],
    expires_in: 1.hour,
    namespace: "cache"
  }

  # require 'syslog/logger'
  # config.logger = ActiveSupport::TaggedLogging.new(Syslog::Logger.new 'app-name')

  if ENV["RAILS_LOG_TO_STDERR"].present?
    logger           = ActiveSupport::Logger.new(STDERR)
    logger.formatter = config.log_formatter
    config.logger = ActiveSupport::TaggedLogging.new(logger)
  end
  if ENV["RAILS_LOG_TO_STDOUT"].present?
    logger           = ActiveSupport::Logger.new(STDOUT)
    logger.formatter = config.log_formatter
    config.logger = ActiveSupport::TaggedLogging.new(logger)
  end
  
  # # Enable/disable caching. By default caching is disabled.
  # if Rails.root.join('tmp/caching-dev.txt').exist?
  #   config.action_controller.perform_caching = true

  #   config.cache_store = :memory_store
  #   config.public_file_server.headers = {
  #     'Cache-Control' => 'public, max-age=172800'
  #   }
  # else
  #   config.action_controller.perform_caching = false

  #   config.cache_store = :null_store
  # end

  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.default_url_options = if ENV['APP_DOMAIN']
    { host: "https://#{ENV['APP_DOMAIN']}" }
  else
    { host: 'http://localhost', port: ENV['PORT'] || 3002 }
  end
  config.action_mailer.perform_caching = false
  # config.action_controller.asset_host = "#{config.action_mailer.default_url_options[:host]}:#{config.action_mailer.default_url_options[:port]}"
  config.action_mailer.asset_host = config.action_controller.asset_host

  if ENV['MAILTRAP_API_TOKEN'].present? && ENV['MAILTRAP_ACCOUNT_ID'].present?
    begin
      config.action_mailer.perform_deliveries = true
      response = RestClient.get(
        "https://mailtrap.io/api/accounts/#{ENV['MAILTRAP_ACCOUNT_ID']}/inboxes",
        { Authorization: "Bearer #{ENV['MAILTRAP_API_TOKEN']}" }
      )
      parsed = JSON.parse(response)
      inbox = parsed.is_a?(Array) ? parsed[0] : parsed["inboxes"][0]
      config.action_mailer.delivery_method = :smtp
      config.action_mailer.smtp_settings = {
        :user_name => inbox['username'],
        :password => inbox['password'],
        :address => inbox['domain'],
        :domain => inbox['domain'],
        :port => 2525,
        :authentication => :plain
      }
      $stderr.puts "[Mailer] Using Mailtrap for email delivery"
    rescue RestClient::Exception, StandardError => e
      $stderr.puts "[Mailer] Mailtrap setup failed: #{e.message} — falling back to next provider"
    end
  elsif ENV['GMAIL_USERNAME'].present?
    config.action_mailer.perform_deliveries = true
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
      authentication: :plain,
      address:        'smtp.gmail.com',
      port:           587,
      domain:         ENV['APP_DOMAIN'] || 'localhost',
      user_name:      ENV['GMAIL_USERNAME'],
      password:       ENV['GMAIL_PASSWORD']
    }
    $stderr.puts "[Mailer] Using Gmail SMTP for email delivery"
  elsif ENV['SMTP_USERNAME'].present?
    config.action_mailer.perform_deliveries = true
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
      authentication: :login,
      address:        ENV['SMTP_ADDRESS'],
      host:           ENV['SMTP_ADDRESS'],
      port:           (ENV['SMTP_PORT'] || 587).to_i,
      user_name:      ENV['SMTP_USERNAME'],
      password:       ENV['SMTP_PASSWORD'],
      enable_starttls_auto: true
    }
    $stderr.puts "[Mailer] Using SMTP server #{ENV['SMTP_ADDRESS']} for email delivery"
  else
    config.action_mailer.perform_deliveries = true
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
      address: 'localhost',
      port:    25
    }
    $stderr.puts "[Mailer] WARNING: No mail provider configured — falling back to localhost:25"
  end
  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise an error on page load if there are pending migrations.
  # config.active_record.migration_error = :page_load

  # Debug mode disables concatenation and preprocessing of assets.
  # This option may cause significant delays in view rendering with a large
  # number of complex assets.
  config.assets.debug = true

  # Suppress logger output for asset requests.
  config.assets.quiet = true

  # Raises error for missing translations
  # config.action_view.raise_on_missing_translations = true

  # Use an evented file watcher to asynchronously detect changes in source code,
  # routes, locales, etc. This feature depends on the listen gem.
  config.file_watcher = ActiveSupport::EventedFileUpdateChecker

  
end
