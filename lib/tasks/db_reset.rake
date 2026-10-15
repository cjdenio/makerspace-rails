namespace :db do
  desc "Clears and reseeds the db. Runs in test and development, never production."
  task :db_reset, [:options] => :environment do |t, args|
    if Rails.env.production?
      puts "db:db_reset refused to run in production."
      exit 1
    end

    require Rails.root.join('lib/service/database_safety')
    ::Service::DatabaseSafety.ensure_safe_mlab_uri!(operation: 'db:db_reset')

    require 'factory_bot'
    require "database_cleaner/mongoid"

    puts "Cleaning db..."

    Dir[Rails.root.join('spec/support/**/*.rb')].each { |f| require f }
    DatabaseCleaner.strategy = :deletion
    DatabaseCleaner.clean
    FactoryBot.rewind_sequences

    # Braintree cleanup options — only meaningful in test (CI) where we want a
    # clean sandbox. Skipped in development to preserve local sandbox data.
    if Rails.env.test?
      braintree_options = (args[:options] || "").split(",").map(&:to_sym)

      if braintree_options.length > 0
        gateway = ::Service::BraintreeGateway.connect_gateway
        cancel_subscriptions(gateway) if braintree_options.include?(:subscriptions)
        delete_payment_methods(gateway) if braintree_options.include?(:payment_methods)
      end
    end

    puts "DB cleaned, seeding..."
    SeedData.new.call
    puts "Creating verified unique indexes..."
    Rake::Task["data:ensure_unique_indexes"].reenable
    Rake::Task["data:ensure_unique_indexes"].invoke
    puts "Seeding complete, done."
  end

  # Seed N approved volunteer credits for a member.
  # Used by E2E tests to bring a member to the discount threshold
  # without going through the full task claim/verify UI flow.
  #
  # Usage: rake "db:seed_volunteer_credits[member@email.com,2]"
  # Defaults to 1 credit if count not specified.
  task :seed_volunteer_credits, [:member_email, :count] => :environment do |t, args|
    email = args[:member_email]
    count = (args[:count] || 1).to_i

    if email.blank?
      puts "Usage: rake \"db:seed_volunteer_credits[member@email.com,2]\""
      exit 1
    end

    member = Member.find_by(email: email)
    if member.nil?
      puts "Member not found: #{email}"
      exit 1
    end

    admin = Member.find_by(email: "admin_member0@test.com")
    if admin.nil?
      puts "admin_member0@test.com not found — seed not run?"
      exit 1
    end

    count.times do |i|
      credit = VolunteerCredit.new(
        member_id:    member.id,
        issued_by_id: admin.id,
        description:  "E2E test credit #{i + 1}",
        credit_value: 1.0,
        status:       'approved'
      )
      credit.save!(validate: false)
      # Manually trigger discount check since save!(validate: false) skips callbacks
      credit.send(:check_and_apply_discount!) rescue nil
    end

    year_total = VolunteerCredit.year_count_for(member.id)
    puts "Seeded #{count} credits for #{member.fullname}. Year total: #{year_total}"
  end

  task :reject_card, [:number] => :environment do |t, args|
    require 'factory_bot'
    Dir[Rails.root.join('spec/support/**/*.rb')].each { |f| require f }

    if args[:number].nil? then
      last_card = RejectionCard.all.last
      new_uid = last_card.nil? ? "0001" : ("%04d" % (last_card.uid.to_i + 1))
    else
      new_uid = args[:number]
    end
    rejection_card = FactoryBot.create(:rejection_card, uid: "#{new_uid}")
  end

  task :braintree_webhook, [:member_email] => :environment do |t, args|
    if args[:member_email] then
      member = Member.find_by(email: args[:member_email])
      invoice = Invoice.active_invoice_for_resource(member.id)
      sample_notification = ::Service::BraintreeGateway.connect_gateway.webhook_testing.sample_notification(
        Braintree::WebhookNotification::Kind::SubscriptionCanceled,
        invoice.subscription_id
      )

      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.post "/billing/braintree_listener", { params: sample_notification }
    end
  end

  task :paypal_webhook, [:member_email] => :environment do |t, args|
    if args[:member_email] then
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.post "/ipnlistener", { params: {
        "payer_email" => args[:member_email],
        "txn_type": "subscr_cancel"
        } }
    end
  end

  # Toggles the signup maintenance lockout flag directly, without going
  # through the (currently flaky) Portal Settings UI.
  # Usage: rake "db:set_signup_lockout[true]"  /  rake "db:set_signup_lockout[false]"
  task :set_signup_lockout, [:enabled] => :environment do |t, args|
    enabled = args[:enabled].to_s.strip.downcase

    unless %w[true false].include?(enabled)
      puts 'Usage: rake "db:set_signup_lockout[true]" or rake "db:set_signup_lockout[false]"'
      exit 1
    end

    SystemConfig.set(SystemConfig::SIGNUP_LOCKOUT_ENABLED, enabled)
    puts "signup_lockout_enabled set to #{enabled}"
  end
end

def cancel_subscriptions(gateway)
  subscriptions = ::BraintreeService::Subscription.get_subscriptions(gateway, Proc.new do |search|
    search.status.in(
      Braintree::Subscription::Status::Active,
      Braintree::Subscription::Status::Expired,
      Braintree::Subscription::Status::PastDue,
      Braintree::Subscription::Status::Pending
    )
  end)
  results = subscriptions.map do |subscription|
    ::BraintreeService::Subscription.cancel(gateway, subscription.id)
  end.compact
  evaluate_results(results)
end

def delete_payment_methods(gateway)
  customers = Member.where(:customer_id.nin => ["", nil])
  results = []

  customers.each do |customer|
    payment_methods = ::BraintreeService::PaymentMethod.get_payment_methods_for_customer(gateway, customer.customer_id)
    payment_methods.each do |payment_method|
      result = ::BraintreeService::PaymentMethod.delete_payment_method(gateway, payment_method.token)
      results.push(result)
    end
  end

  evaluate_results(results)
end

def evaluate_results(results)
  failures = results.select { |r| !r.success? }
  if failures.length > 0
    failures.each do |failure|
      failure.errors.each do |error|
        STDERR.puts error.attribute
        STDERR.puts error.code
        STDERR.puts error.message
      end
    end
  end
end

namespace :db do
  desc "Seeds historical analytics data without wiping existing records. Safe to run on production."
  task :seed_analytics => :environment do
    require 'factory_bot'
    Dir[Rails.root.join('spec/support/**/*.rb')].each { |f| require f }

    puts "Seeding historical analytics data (non-destructive)..."
    seeder = SeedData.new
    seeder.send(:create_historical_members)
    seeder.send(:create_historical_invoices)
    seeder.send(:create_historical_rentals)
    seeder.send(:create_historical_checkouts)
    seeder.send(:create_historical_volunteer_data)
    seeder.send(:create_historical_checkins)
    seeder.send(:create_membership_snapshots)
    puts "Analytics seeding complete."
  end
end
