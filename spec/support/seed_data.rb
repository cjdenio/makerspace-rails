require 'factory_bot'
Dir[Rails.root.join('spec/support/**/*.rb')].each { |f| require f }

class SeedData
  include FactoryBot::Syntax::Methods

  # ── Constants ─────────────────────────────────────────────────────────────

  # E2E test members — go through real Braintree sandbox
  MEMBER_COUNT = 13

  # Historical analytics members — no Braintree, just direct DB records
  HISTORICAL_MEMBER_COUNT = 20

  # How many years of historical data to generate
  HISTORY_YEARS = 3

  # Checkins per month per active member (random range)
  CHECKINS_PER_MONTH_MIN = 20
  CHECKINS_PER_MONTH_MAX = 30

  SANDBOX_VISA_NONCE = "fake-valid-visa-nonce".freeze
  SANDBOX_PLAN_ID    = "membership-one-month-recurring".freeze

  VOLUNTEER_TASK_TITLES = [
    ["Sweep woodshop floor",         "Sweep sawdust and debris from all floors in the woodshop"],
    ["Organize lumber rack",          "Sort and label all lumber bins by species and dimension"],
    ["Clean laser bed",               "Wipe down the laser cutter bed and lens with isopropyl"],
    ["Restock consumables",           "Check and restock sandpaper, gloves, and safety glasses"],
    ["Label tool storage",            "Print and affix labels to all unlabeled tool drawers"],
    ["Wipe down 3D printers",         "Clean print beds and wipe down all 3D printer exteriors"],
    ["Coil and store extension cords","Coil all loose extension cords and hang on wall hooks"],
    ["Clean electronics workbench",   "Organize components, toss trash, wipe down bench surface"],
    ["Sort scrap metal bin",          "Sort scrap metal by type and move oversized pieces to dumpster"],
    ["Restock first aid kit",         "Inventory and restock the main first aid cabinet"],
    ["Check fire extinguishers",      "Walk all shops and verify extinguisher inspection tags are current"],
    ["Clean spray booth filters",     "Remove, wash and dry paint booth intake filters"],
  ].freeze

  # ── Entry Point ───────────────────────────────────────────────────────────

  # Braintree sandbox volunteer discount ID.
  # Must contain 'volunteer' — matched by BraintreeService::Discount.get_volunteer_discounts.
  # This discount must exist in the Braintree sandbox control panel.
  VOLUNTEER_DISCOUNT_ID = "volunteer_discount_10".freeze

  # Threshold set low for E2E testing so tests don't need to create 8 credits.
  VOLUNTEER_CREDITS_PER_DISCOUNT = 2

  # Max discounts per year — keep at 2 to test the cap.
  VOLUNTEER_MAX_DISCOUNTS_PER_YEAR = 2

  def call
    create_permissions
    create_members
    create_board_members
    create_resource_managers
    create_rental_infrastructure
    create_shops_and_tools
    create_rentals
    create_payments
    create_group
    create_rejection_cards
    create_invoice_options
    create_subscriptions
    create_member_cards
    create_volunteer_discount_config
    # Historical analytics data — order matters
    create_historical_members
    create_historical_invoices
    create_historical_rentals
    create_historical_checkouts
    create_historical_volunteer_data
    create_historical_checkins
    create_membership_snapshots
  end

  private

  # ── E2E Members (unchanged) ───────────────────────────────────────────────

  def create_members
    create_expired_members
    create_admins
    MEMBER_COUNT.times do |n|
      create(:member,
        email:          "basic_member#{n}@test.com",
        firstname:      "Basic",
        lastname:       "Member#{n}",
        expirationTime: (Time.now + 1.year).to_i * 1000
      )
    end
    MEMBER_COUNT.times do |n|
      create(:member,
        email:          "paypal_member#{n}@test.com",
        firstname:      "PayPal",
        lastname:       "Member#{n}",
        expirationTime: (Time.now + 1.year).to_i * 1000
      )
    end
  end

  def create_expired_members
    MEMBER_COUNT.times do |n|
      create(:member, :expired,
        email:     "expired_member#{n}@test.com",
        firstname: "Expired",
        lastname:  "Member#{n}"
      )
    end
  end

  def create_admins
    MEMBER_COUNT.times do |n|
      create(:member, :admin,
        email:     "admin_member#{n}@test.com",
        firstname: "Admin",
        lastname:  "Member#{n}"
      )
    end
  end

  def create_board_members
    MEMBER_COUNT.times do |n|
      create(:member, :board_member,
        email:          "board_member#{n}@test.com",
        firstname:      "Board",
        lastname:       "Member#{n}",
        expirationTime: (Time.now + 1.year).to_i * 1000
      )
    end
  end

  def create_resource_managers
    MEMBER_COUNT.times do |n|
      create(:member, :resource_manager,
        email:          "rm_member#{n}@test.com",
        firstname:      "Resource",
        lastname:       "Manager#{n}",
        expirationTime: (Time.now + 1.year).to_i * 1000
      )
    end
  end

  # ── Rental Infrastructure ─────────────────────────────────────────────────

  def create_rental_infrastructure
    create_rental_invoice_options
    create_rental_types
    create_rental_spots
    puts "  [seed] Rental infrastructure: #{RentalType.count} types, #{RentalSpot.count} spots."
  end

  def create_rental_invoice_options
    [
      { name: "Monthly Tote Rental", description: "Tote rental subscription automatically renews every month on the day the subscription started.", amount: 15.0, quantity: 1, resource_class: "rental", plan_id: "rental-monthly-tote", operation: "renew=", disabled: false },
      { name: "One Month Back Shop Shelf Rental", description: "Full shelf rental subscription automatically renews every month.", amount: 50.0, quantity: 1, resource_class: "rental", plan_id: "2023-rental-month-Back-Shelf", operation: "renew=", disabled: false },
      { name: "One Month Half Back Shop Shelf Rental", description: "Half shelf rental subscription automatically renews every month.", amount: 30.0, quantity: 1, resource_class: "rental", plan_id: "2023-rental-month-Half-Back-Shelf", operation: "renew=", disabled: false },
    ].each do |opt|
      next if InvoiceOption.where(plan_id: opt[:plan_id]).exists?
      InvoiceOption.create!(opt)
    end
  end

  def create_rental_types
    tote_opt       = InvoiceOption.find_by(plan_id: "rental-monthly-tote")
    half_shelf_opt = InvoiceOption.find_by(plan_id: "2023-rental-month-Half-Back-Shelf")
    full_shelf_opt = InvoiceOption.find_by(plan_id: "2023-rental-month-Back-Shelf")
    [
      { display_name: "Storage Tote",  invoice_option: tote_opt,       active: true },
      { display_name: "Full Shelf",    invoice_option: full_shelf_opt,  active: true },
      { display_name: "Half Shelf",    invoice_option: half_shelf_opt,  active: true },
      { display_name: "Parking Space", invoice_option: nil,             active: true },
      { display_name: "Plot",          invoice_option: nil,             active: true },
    ].each do |rt|
      next if RentalType.where(display_name: rt[:display_name]).exists?
      RentalType.create!(display_name: rt[:display_name], active: rt[:active], invoice_option_id: rt[:invoice_option]&.id&.to_s)
    end
  end

  def create_rental_spots
    tote_type       = RentalType.find_by(display_name: "Storage Tote")
    full_shelf_type = RentalType.find_by(display_name: "Full Shelf")
    half_shelf_type = RentalType.find_by(display_name: "Half Shelf")
    parking_type    = RentalType.find_by(display_name: "Parking Space")
    [
      { number: "LR-Tote-1", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "LR-Tote-2", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "LR-Tote-3", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "LR-Tote-4", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "LR-Tote-5", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "LR-Tote-6", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "BS-Tote-1", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "BS-Tote-2", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "BS-Tote-3", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "BS-Tote-4", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "BS-Tote-5", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "BS-Tote-6", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "Shelf-1",   location: "Back Shop",   description: "Full Shelf", rental_type: full_shelf_type, requires_approval: false, parent_number: nil },
      { number: "Shelf-2",   location: "Back Shop",   description: "Full Shelf", rental_type: full_shelf_type, requires_approval: false, parent_number: nil },
      { number: "Shelf-3",   location: "Back Shop",   description: "Full Shelf", rental_type: full_shelf_type, requires_approval: false, parent_number: nil },
      { number: "Shelf-4",   location: "Back Shop",   description: "Full Shelf", rental_type: full_shelf_type, requires_approval: false, parent_number: nil },
      { number: "Shelf-1a",  location: "Back Shop",   description: "Half Shelf (left)",  rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-1" },
      { number: "Shelf-1b",  location: "Back Shop",   description: "Half Shelf (right)", rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-1" },
      { number: "Shelf-2a",  location: "Back Shop",   description: "Half Shelf (left)",  rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-2" },
      { number: "Shelf-2b",  location: "Back Shop",   description: "Half Shelf (right)", rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-2" },
      { number: "Shelf-3a",  location: "Back Shop",   description: "Half Shelf (left)",  rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-3" },
      { number: "Shelf-3b",  location: "Back Shop",   description: "Half Shelf (right)", rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-3" },
      { number: "Shelf-4a",  location: "Back Shop",   description: "Half Shelf (left)",  rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-4" },
      { number: "Shelf-4b",  location: "Back Shop",   description: "Half Shelf (right)", rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-4" },
      { number: "Garage-1",  location: "Auto Bay",    description: "Auto Bay Overnight",     rental_type: parking_type, requires_approval: true, parent_number: nil },
      { number: "Parking-1", location: "Outside",     description: "Overnight Parking Spot", rental_type: parking_type, requires_approval: true, parent_number: nil },
    ].each do |s|
      next if RentalSpot.where(number: s[:number]).exists?
      RentalSpot.create!(
        number: s[:number], location: s[:location], description: s[:description],
        rental_type_id: s[:rental_type]&.id&.to_s, requires_approval: s[:requires_approval],
        active: true, parent_number: s[:parent_number]
      )
    end
  end

  # ── Shops and Tools ───────────────────────────────────────────────────────

  def create_shops_and_tools
    return if Shop.count > 0
    shop_data = [
      {
        name: "Facilities",
        slack_channel: "facilities",
        tools: [{
          name: "Orientation",
          description: "Orientation is your first step towards active membership, and is available during scheduled Open House hours or by special arrangement",
          reservable: true,
          max_concurrent_reservations: 6,
          reservation_horizon_days: 15,
          max_reservation_duration_hours: 0.5,
          allow_pending: true
        }]
      },
      { name: "3D Printers",  slack_channel: "shop-3dprinting",  tools: ["Prusa MK4", "Bambu X1C"] },
      { name: "Woodshop",     slack_channel: "shop-woodworking",  tools: ["Table Saw", "Band Saw", "Planer", "Jointer", "Drill Press"] },
      { name: "Metal Shop",   slack_channel: "shop-metalwork",    tools: ["MIG Welder", "TIG Welder", "Angle Grinder", "Metal Lathe"] },
      { name: "Laser",        slack_channel: "shop-lasercutter",  tools: ["Laser Cutter 60W", "Laser Cutter 100W"] },
      { name: "Electronics",  slack_channel: "shop-electronics",  tools: ["Oscilloscope", "Soldering Station", "PCB Mill"] },
      { name: "Textile Arts", slack_channel: "shop-textile-arts", tools: ["Sewing Machine", "Embroidery Machine", "Serger"] },
      { name: "Automotive",   slack_channel: "shop-automotive",   tools: ["Floor Jack", "OBD Scanner"] },
      { name: "Paint",        slack_channel: "shop-paint",        tools: ["Spray Gun", "Air Compressor"] },
    ]
    shop_data.each do |s|
      shop = Shop.create!(name: s[:name], slack_channel: s[:slack_channel])
      s[:tools].each do |tool_data|
        attributes = tool_data.is_a?(Hash) ? tool_data : {
          name: tool_data,
          description: "#{tool_data} in #{s[:name]}"
        }
        Tool.create!(attributes.merge(shop: shop))
      end
    end
    shop_ids = Shop.all.pluck(:id).map(&:to_s)
    Member.where(role: "resource_manager").each do |member|
      member.set(resource_manager_shop_ids: shop_ids)
    end
    puts "  [seed] Created #{Shop.count} shops with #{Tool.count} tools."
  end

  # ── E2E Rentals ───────────────────────────────────────────────────────────

  def create_rentals
    assignable_spots = RentalSpot.where(requires_approval: false, active: true).to_a
    members = Member.where(:email.nin => ["household_primary@test.com", "household_secondary@test.com"])
                    .limit(assignable_spots.length).to_a
    assignable_spots.each_with_index do |spot, i|
      member = members[i % members.length]
      next unless member
      Rental.create!(
        member: member, number: spot.number, rental_spot_id: spot.id.to_s,
        description: spot.description, expiration: (Time.now + (i % 6 + 1).months).to_i * 1000,
        status: "active", contract_signed_date: Date.today
      )
    end
    puts "  [seed] Created #{Rental.count} rentals linked to spots."
  end

  # ── Other E2E Data ────────────────────────────────────────────────────────

  def create_payments
    10.times { create(:payment) }
  end

  def create_group
    primary = create(:member,
      email: "household_primary@test.com", firstname: "Household", lastname: "Primary",
      expirationTime: (Time.now + 1.year).to_i * 1000,
      address_street: "42 Elm Street", address_city: "Manchester",
      address_state: "NH", address_postal_code: "03101"
    )
    secondary = create(:member,
      email: "household_secondary@test.com", firstname: "Household", lastname: "Secondary",
      expirationTime: (Time.now + 6.months).to_i * 1000,
      address_street: "42 Elm Street", address_city: "Manchester",
      address_state: "NH", address_postal_code: "03101"
    )
    Invoice.create!(
      member: primary, name: "Household Membership", description: "Household membership plan",
      amount: 85.0, quantity: 1, plan_id: "household-membership-one-month-recurring",
      resource_class: "member", resource_id: primary.id, operation: "renew=",
      due_date: Time.now + 1.month, settled_at: Time.now
    )
    Group.create!(groupName: primary.id.to_s, groupRep: primary.fullname, expiry: primary.expirationTime)
    primary.update!(groupName: primary.id.to_s)
    secondary.update!(groupName: primary.id.to_s, expirationTime: primary.expirationTime)
    puts "  [seed] Created household: #{primary.fullname} + #{secondary.fullname}"
  end

  def create_rejection_cards
    create(:rejection_card, uid: '0000', timeOf: Date.today)
    create(:rejection_card, uid: '0001', timeOf: Date.today)
    create(:rejection_card, uid: '0002', timeOf: Date.today)
  end

  def create_invoice_options
    create(:invoice_option, name: "One Month",    amount: 65.0,  id: "one-month",    plan_id: "membership-one-month-recurring",    discount_id: "monthly_membership_sso")
    create(:invoice_option, name: "Three Months", amount: 190.0, id: "three-months", plan_id: "membership-three-month-recurring",  discount_id: "quarterly_membership_sso")
    create(:invoice_option, name: "One Year",     amount: 765.0, id: "one-year",     plan_id: "membership-twelve-month-recurring", discount_id: "annual_membership_sso")
    create(:invoice_option,
      name: "Household Monthly Membership Subscription", amount: 125.0, id: "household-one-month",
      plan_id: "2024_household-membership-one-month-recurring",
      description: "Membership subscription for two adults in the same household, automatically renews every month on the day the subscription started"
    )
  end

  def create_permissions
    DefaultPermission.create(name: :billing,           enabled: true)
    DefaultPermission.create(name: :custom_billing,    enabled: false)
    DefaultPermission.create(name: :earned_membership, enabled: true)
  end

  # ── FOB Cards for Braintree members ──────────────────────────────────────

  def create_member_cards
    subscribed_members = Member.where(subscription: true)
    created = 0
    subscribed_members.each do |member|
      next if Card.where(member_id: member.id).exists?
      Card.create!(
        member_id: member.id, uid: SecureRandom.hex(7).upcase,
        holder: member.fullname, validity: member.status, expiry: member.expirationTime
      )
      created += 1
    end
    puts "  [seed] Created #{created} member cards (#{Card.count} total)."
  end

  # ── Braintree Subscriptions ───────────────────────────────────────────────

  def create_subscriptions
    gateway        = Service::BraintreeGateway.connect_gateway
    invoice_option = InvoiceOption.find("one-month")
    {
      "basic_member"  => "Basic",
      "admin_member"  => "Admin",
      "board_member"  => "Board",
      "rm_member"     => "Resource Manager",
    }.each do |prefix, label|
      MEMBER_COUNT.times do |n|
        member = Member.find_by(email: "#{prefix}#{n}@test.com")
        if member
          seed_subscription_for(member, invoice_option, gateway, SANDBOX_VISA_NONCE)
        else
          puts "  [seed] Warning: #{label} member #{n} not found, skipping subscription."
        end
      end
    end
  end

  def seed_subscription_for(member, invoice_option, gateway, nonce)
    results           = gateway.customer.search { |s| s.email.is(member.email) }
    existing_customer = results.first
    if existing_customer
      active_sub = find_active_subscription(existing_customer)
      if active_sub
        reconnect_member(member, existing_customer, active_sub, invoice_option)
        puts "  [seed] Reused subscription for #{member.fullname}: #{active_sub.id}"
        return
      end
      # NOTE: previously this fell through to creating a new subscription on
      # the SAME existing customer/payment method when no active subscription
      # was found. Braintree subscriptions cannot be deleted or reactivated
      # once cancelled, so every seed run that found a cancelled subscription
      # here left it behind permanently and created another — across months
      # of CI/local runs this accumulated 130+ cancelled subscriptions on a
      # single sandbox customer, which appears to interfere with Braintree's
      # subscription search results for that customer (e.g. via
      # Admin::Billing::SubscriptionsController's search-scoped query).
      # Creating a fresh customer instead avoids growing that history further.
      puts "  [seed] No active subscription for #{member.fullname} — creating fresh Braintree customer instead of reusing #{existing_customer.id}"
    end
    result = gateway.customer.create(
      first_name: member.firstname, last_name: member.lastname,
      email: member.email, payment_method_nonce: nonce
    )
    unless result.success?
      puts "  [seed] Warning: Could not create Braintree customer for #{member.fullname}: #{result.message}"
      return
    end
    member.update!(customer_id: result.customer.id)
    create_braintree_subscription(member, invoice_option, result.customer.payment_methods.first.token, gateway)
  end

  def find_active_subscription(customer)
    customer.payment_methods.each do |pm|
      pm.subscriptions.each do |sub|
        return sub if sub.status == Braintree::Subscription::Status::Active
      end
    end
    nil
  end

  def reconnect_member(member, customer, subscription, invoice_option)
    member.update!(
      customer_id: customer.id, subscription_id: subscription.id,
      subscription: true, expirationTime: subscription.paid_through_date.to_time.to_i * 1000
    )
    Invoice.create!(
      member: member, name: invoice_option.name, description: invoice_option.description,
      amount: invoice_option.amount, quantity: invoice_option.quantity,
      plan_id: invoice_option.plan_id, payment_method_id: subscription.payment_method_token,
      resource_class: "member", resource_id: member.id, operation: invoice_option.operation,
      subscription_id: subscription.id, due_date: subscription.next_billing_date, settled_at: Time.now
    )
  end

  def create_braintree_subscription(member, invoice_option, payment_method_token, gateway)
    invoice = Invoice.create!(
      member: member, name: invoice_option.name, description: invoice_option.description,
      amount: invoice_option.amount, quantity: invoice_option.quantity,
      plan_id: invoice_option.plan_id, payment_method_id: payment_method_token,
      resource_class: "member", resource_id: member.id, operation: invoice_option.operation,
      due_date: Time.now + 1.month
    )
    subscription_id = invoice.generate_subscription_id
    result = gateway.subscription.create(
      payment_method_token: payment_method_token,
      plan_id: SANDBOX_PLAN_ID,
      id: subscription_id
    )
    unless result.success?
      puts "  [seed] Warning: Could not create subscription for #{member.fullname}: #{result.message}"
      return
    end
    member.update!(subscription_id: subscription_id, subscription: true, expirationTime: (Time.now + invoice_option.quantity.months).to_i * 1000)
    invoice.update!(subscription_id: subscription_id, settled_at: Time.now)
    puts "  [seed] Created subscription for #{member.fullname}: #{subscription_id}"
  end

  # ── Volunteer Discount System Config ─────────────────────────────────────
  #
  # Seeds the three SystemConfig keys that drive the volunteer credit/discount
  # system. Without these the discount UI is hidden (discount_active: false)
  # and check_discount_threshold! is a no-op.
  #
  # VOLUNTEER_CREDITS_PER_DISCOUNT is set to 2 (not the production default of 8)
  # so E2E tests only need to award two credits to trigger a discount.

  def create_volunteer_discount_config
    {
      'volunteer_discount_id'            => VOLUNTEER_DISCOUNT_ID,
      'volunteer_credits_per_discount'   => VOLUNTEER_CREDITS_PER_DISCOUNT.to_s,
      'volunteer_max_discounts_per_year' => VOLUNTEER_MAX_DISCOUNTS_PER_YEAR.to_s,
    }.each do |key, value|
      SystemConfig.set(key, value) unless SystemConfig.get(key).present?
    end
    puts "  [seed] Volunteer discount config: discount_id=#{VOLUNTEER_DISCOUNT_ID}, " \
         "threshold=#{VOLUNTEER_CREDITS_PER_DISCOUNT}, max=#{VOLUNTEER_MAX_DISCOUNTS_PER_YEAR}"
  end

  # ── Historical Members ────────────────────────────────────────────────────
  #
  # 20 members seeded directly — no Braintree calls.
  # startDate spread across HISTORY_YEARS so the membership growth chart
  # shows realistic month-over-month trends.
  # Each member gets a card UID for checkin matching.

  def create_historical_members
    first_names = %w[James Emma Liam Olivia Noah Ava William Sophia Benjamin Isabella
                     Elijah Mia Lucas Charlotte Mason Amelia Ethan Harper Alexander Evelyn]
    last_names  = %w[Smith Johnson Williams Brown Jones Garcia Miller Davis Wilson Moore
                     Taylor Anderson Thomas Jackson White Harris Martin Thompson Lee Walker]

    total_months = HISTORY_YEARS * 12
    months_per_member = total_months.to_f / HISTORICAL_MEMBER_COUNT

    HISTORICAL_MEMBER_COUNT.times do |n|
      # Skip if already seeded (idempotent)
      next if Member.where(email: "hist_member#{n}@test.com").exists?

      # Spread join dates evenly across the history window
      months_ago  = (total_months - (n * months_per_member)).round
      join_date   = months_ago.months.ago
      # Members stay active for 1-3 years from join date
      active_years = [1, 1, 2, 2, 3].sample
      expiry_time  = join_date + active_years.years

      # Some members are now expired, some still active
      is_active = expiry_time > Time.now
      status    = is_active ? 'activeMember' : 'inactive'

      member = Member.create!(
        email:          "hist_member#{n}@test.com",
        firstname:      first_names[n % first_names.length],
        lastname:       last_names[(n + 7) % last_names.length],
        role:           'member',
        status:         status,
        startDate:      join_date,
        expirationTime: expiry_time.to_i * 1000,
        subscription:   true,
        address_street:      "#{100 + n} Main St",
        address_city:        "Manchester",
        address_state:       "NH",
        address_postal_code: "03101"
      )

      # Issue a card so checkins can be attributed
      Card.create!(
        member_id: member.id,
        uid:       SecureRandom.hex(7).upcase,
        holder:    member.fullname,
        validity:  member.status,
        expiry:    member.expirationTime
      )
    end
    puts "  [seed] Created #{HISTORICAL_MEMBER_COUNT} historical members with cards."
  end

  # ── Historical Invoices ───────────────────────────────────────────────────
  #
  # One settled invoice per year per historical member.
  # No Braintree subscription_id — these are direct payment records.
  # Callbacks skipped for past-dated invoice creation to avoid side effects.

  def create_historical_invoices
    historical_members = Member.where(:email.in => (0...HISTORICAL_MEMBER_COUNT).map { |n| "hist_member#{n}@test.com" })
    count = 0

    historical_members.each do |member|
      join_date   = member.startDate || HISTORY_YEARS.years.ago
      expiry_time = Time.at(member.expirationTime / 1000.0)
      active_years = ((expiry_time - join_date) / 1.year).ceil.clamp(1, HISTORY_YEARS)

      active_years.times do |year_offset|
        invoice_date = join_date + year_offset.years
        next if invoice_date > Time.now

        # Use skip_callback to avoid triggering Braintree/email side effects
        Invoice.skip_callback(:create, :after, :send_rental_email)
        Invoice.skip_callback(:save,   :before, :set_due_date)
        begin
          Invoice.create!(
            member:         member,
            name:           "Annual Membership — #{invoice_date.year}",
            description:    "Annual membership payment",
            amount:         65.0,
            quantity:       1,
            resource_class: "member",
            resource_id:    member.id.to_s,
            operation:      "renew=",
            plan_id:        "membership-one-month-recurring",
            due_date:       invoice_date + 1.month,
            settled_at:     invoice_date,
            created_at:     invoice_date
          )
          count += 1
        rescue => e
          puts "  [seed] Warning: Could not create invoice for #{member.fullname}: #{e.message}"
        ensure
          Invoice.set_callback(:create, :after, :send_rental_email)
          Invoice.set_callback(:save,   :before, :set_due_date)
        end
      end
    end
    puts "  [seed] Created #{count} historical invoices."
  end

  # ── Historical Rentals ────────────────────────────────────────────────────
  #
  # Assign rentals to historical members with historical contract dates.

  def create_historical_rentals
    historical_members = Member.where(:email.in => (0...HISTORICAL_MEMBER_COUNT).map { |n| "hist_member#{n}@test.com" }).to_a
    available_spots    = RentalSpot.where(requires_approval: false, active: true).to_a
    count = 0

    # Assign a spot to every other historical member
    historical_members.each_with_index do |member, i|
      next if i.odd?
      spot = available_spots[i % available_spots.length]
      next unless spot

      # Skip spots already rented
      next if Rental.where(number: spot.number, :status.in => %w[active pending]).exists?

      join_date = member.startDate || 2.years.ago
      Rental.create!(
        member:               member,
        number:               "HIST-#{SecureRandom.hex(4).upcase}",
        rental_spot_id:       spot.id.to_s,
        description:          spot.description,
        expiration:           (Time.now + 6.months).to_i * 1000,
        status:               member.status == 'activeMember' ? 'active' : 'cancelled',
        contract_signed_date: join_date.to_date
      )
      count += 1
    end
    puts "  [seed] Created #{count} historical rentals."
  end

  # ── Historical Tool Checkouts ─────────────────────────────────────────────
  #
  # Check out each historical active member on 2-4 tools.
  # checked_out_at spread across their membership period.

  def create_historical_checkouts
    tools   = Tool.all.to_a
    return if tools.empty?

    admin   = Member.find_by(email: "admin_member0@test.com")
    return unless admin

    historical_members = Member.where(:email.in => (0...HISTORICAL_MEMBER_COUNT).map { |n| "hist_member#{n}@test.com" }).to_a
    count = 0

    historical_members.each do |member|
      join_date    = member.startDate || 2.years.ago
      checkout_tools = tools.sample(rand(2..4))

      checkout_tools.each_with_index do |tool, i|
        checkout_date = join_date + (i + 1).months
        next if checkout_date > Time.now

        ToolCheckout.create!(
          member:       member,
          tool:         tool,
          approved_by:  admin,
          checked_out_at: checkout_date,
          signed_off_via: "portal"
        )
        count += 1
      end
    end
    puts "  [seed] Created #{count} historical tool checkouts."
  end

  # ── Historical Volunteer Data ─────────────────────────────────────────────
  #
  # Creates completed volunteer tasks and associated credits spread across
  # the full history window. Each task goes through the full lifecycle:
  #   created → claimed → pending → completed (with credit issued)
  #
  # Uses Timecop-style timestamp manipulation via direct field assignment
  # since we need historical created_at/completed_at values.

  def create_historical_volunteer_data
    # Skip if already seeded
    if VolunteerTask.where(:title.in => VOLUNTEER_TASK_TITLES.map(&:first)).exists?
      puts "  [seed] Historical volunteer data already seeded, skipping."
      return
    end

    admin   = Member.find_by(email: "admin_member0@test.com")
    return unless admin

    historical_members = Member.where(
      :email.in => (0...HISTORICAL_MEMBER_COUNT).map { |n| "hist_member#{n}@test.com" },
      status:      'activeMember'
    ).to_a
    return if historical_members.empty?

    total_months   = HISTORY_YEARS * 12
    tasks_per_month = 2
    count_tasks    = 0
    count_credits  = 0

    total_months.times do |month_offset|
      task_date = month_offset.months.ago

      tasks_per_month.times do |t|
        title_data  = VOLUNTEER_TASK_TITLES[(month_offset * tasks_per_month + t) % VOLUNTEER_TASK_TITLES.length]
        claim_date  = task_date + 3.days
        done_date   = claim_date + 2.days
        verify_date = done_date + 1.day
        next if verify_date > Time.now

        claimant = historical_members[(month_offset + t) % historical_members.length]

        # Create parent task
        task = VolunteerTask.new(
          title:         title_data[0],
          description:   title_data[1],
          credit_value:  [0.5, 1.0, 1.0, 1.5].sample,
          created_by_id: admin.id,
          status:        'available'
        )
        task.save!
        task.set(created_at: task_date)

        # Claim
        task.update!(status: 'claimed', claimed_by_id: claimant.id, claimed_at: claim_date)

        # Mark pending
        task.update!(status: 'pending', completed_at: done_date)

        # Verify and issue credit — bypass model callbacks for historical timestamps
        task.update!(status: 'completed', verified_by_id: admin.id)

        credit = VolunteerCredit.new(
          member_id:    claimant.id,
          issued_by_id: admin.id,
          task_id:      task.id,
          description:  "Completed bounty task: #{title_data[0]}",
          credit_value: task.credit_value,
          status:       'approved'
        )
        credit.save!
        # Set historical timestamps directly
        credit.set(created_at: verify_date)
        credit.set(updated_at: verify_date)

        count_tasks  += 1
        count_credits += 1
      end
    end

    # Also seed a few multi-use task types for UI testing
    seed_multiuse_tasks(admin, historical_members)

    puts "  [seed] Created #{count_tasks} completed volunteer tasks and #{count_credits} credits."
  end

  def seed_multiuse_tasks(admin, members)
    [
      { status: 'reusable',   title: 'Weekly Woodshop Sweep',   description: 'Sweep the woodshop floor and empty the dust collector', days: nil },
      { status: 'repeatable', title: 'Assist at Open House',    description: 'Help run the monthly open house event for prospective members', days: nil },
      { status: 'recurring',  title: 'Restock Consumables',     description: 'Check and restock PPE, sandpaper and other consumables in all shops', days: 14 },
    ].each do |task_attrs|
      task = VolunteerTask.create!(
        title:         task_attrs[:title],
        description:   task_attrs[:description],
        credit_value:  1.0,
        created_by_id: admin.id,
        status:        task_attrs[:status],
        days:          task_attrs[:days]
      )

      # Create 2-3 completed child claims for each multi-use task
      members.first(3).each_with_index do |member, i|
        claim_date  = (i + 1).months.ago
        verify_date = claim_date + 5.days
        next if verify_date > Time.now

        child = VolunteerTask.create!(
          title:          task.title,
          description:    task.description,
          credit_value:   task.credit_value,
          created_by_id:  admin.id,
          parent_task_id: task.id,
          status:         'completed',
          claimed_by_id:  member.id,
          claimed_at:     claim_date,
          completed_at:   claim_date + 3.days,
          verified_by_id: admin.id
        )

        credit = VolunteerCredit.new(
          member_id:    member.id,
          issued_by_id: admin.id,
          task_id:      child.id,
          description:  "Completed bounty task: #{task.title}",
          credit_value: task.credit_value,
          status:       'approved'
        )
        credit.save!
        credit.set(created_at: verify_date)
        credit.set(updated_at: verify_date)
      end
    end

    # Leave one of each type in claimable state for E2E testing
    VolunteerTask.create!(
      title: 'Available Standard Task',   description: 'A standard one-time task ready to claim',
      credit_value: 1.0, created_by_id: admin.id, status: 'available'
    )
    VolunteerTask.create!(
      title: 'Available Reusable Task',   description: 'A reusable task — each member may claim once',
      credit_value: 1.0, created_by_id: admin.id, status: 'reusable'
    )
    VolunteerTask.create!(
      title: 'Available Repeatable Task', description: 'A repeatable task — claim as many times as you like',
      credit_value: 1.0, created_by_id: admin.id, status: 'repeatable'
    )
    VolunteerTask.create!(
      title: 'Available Recurring Task',  description: 'A recurring task — resets every 7 days',
      credit_value: 1.0, created_by_id: admin.id, status: 'recurring', days: 7
    )
  end

  # ── Historical Checkins ───────────────────────────────────────────────────
  #
  # Writes directly to the checkins collection (raw Mongo) to avoid any
  # model layer assumptions. Uses card UIDs from historical members.
  # 20-30 unique member checkins per month for 3 years.

  def create_historical_checkins
    checkins_col = Mongoid.default_client[:checkins]

    # Skip if historical checkins already exist (idempotent)
    hist_uids = Card.where(:member_id.in =>
      Member.where(:email.in => (0...HISTORICAL_MEMBER_COUNT).map { |n| "hist_member#{n}@test.com" }).map(&:id)
    ).map(&:uid)
    if hist_uids.any? && checkins_col.find("uid" => { "$in" => hist_uids }).count > 0
      puts "  [seed] Historical checkins already seeded, skipping."
      return
    end
    cards        = Card.where(:member_id.in =>
      Member.where(:email.in => (0...HISTORICAL_MEMBER_COUNT).map { |n| "hist_member#{n}@test.com" }).map(&:id)
    ).to_a

    return if cards.empty?

    total_months  = HISTORY_YEARS * 12
    total_inserted = 0

    total_months.times do |month_offset|
      # Reference point: first day of this month
      month_start = month_offset.months.ago.beginning_of_month
      month_end   = month_start.end_of_month
      days_in_month = (month_end.to_date - month_start.to_date).to_i + 1

      checkins_this_month = rand(CHECKINS_PER_MONTH_MIN..CHECKINS_PER_MONTH_MAX)

      # Pick random members and random days — deduplicate per member per day
      seen = {}
      attempts = 0
      inserted = 0

      while inserted < checkins_this_month && attempts < checkins_this_month * 3
        attempts += 1
        card = cards.sample
        day  = rand(0..days_in_month - 1)
        key  = "#{card.uid}-#{day}"
        next if seen[key]
        seen[key] = true

        checkin_time = month_start + day.days + rand(6..22).hours + rand(60).minutes
        next if checkin_time > Time.now

        checkins_col.insert_one(
          '_id'     => BSON::ObjectId.new,
          'uid'     => card.uid,
          'timeOf'  => (checkin_time.to_i * 1000),
          'holder'  => card.holder,
          'validity'=> card.validity
        )
        inserted     += 1
        total_inserted += 1
      end
    end

    puts "  [seed] Created #{total_inserted} historical checkin records across #{total_months} months."
  end

  # ── Membership Snapshots ──────────────────────────────────────────────────
  #
  # Generate one snapshot per month for the full history window.
  # Each snapshot records which member IDs were active at the last day of that month.
  # Mirrors the logic in the existing rake task.

  def create_membership_snapshots
    total_months = HISTORY_YEARS * 12
    count = 0

    total_months.times do |month_offset|
      snapshot_date = month_offset.months.ago.end_of_month.to_date
      next if MembershipSnapshot.where(date: snapshot_date).exists?

      snapshot_time_ms = snapshot_date.to_time.to_i * 1000

      active_member_ids = Member.where(
        :startDate.lte      => snapshot_date.to_time,
        :expirationTime.gte => snapshot_time_ms
      ).map { |m| m.id.as_json }

      MembershipSnapshot.create!(
        date:           snapshot_date,
        active_members: active_member_ids
      )
      count += 1
    end

    puts "  [seed] Created #{count} monthly membership snapshots (#{MembershipSnapshot.count} total)."
  end
end
