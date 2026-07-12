# db/seeds_rental_spots.rb
# Run with: rails runner db/seeds_rental_spots.rb
#
# Seeds EXAMPLE data for development only.
# Production data is entered via the Admin UI.
# Invoice option IDs below must be updated to match real production MongoDB IDs.

puts "Seeding rental invoice options..."

RENTAL_INVOICE_OPTIONS = [
  {
    name:           "Monthly Tote Rental",
    description:    "Tote rental subscription automatically renews every month on the day the subscription started.",
    amount:         15.0,
    quantity:       1,
    resource_class: "rental",
    plan_id:        "rental-monthly-tote",
    operation:      "renew=",
    disabled:       false,
  },
  {
    name:           "Quarterly Back Shop Half-Shelf Rental Subscription",
    description:    "Half shelf rental subscription automatically renews every month for 3 months.",
    amount:         19.0,
    quantity:       3,
    resource_class: "rental",
    plan_id:        "rental-quarterly-recurring-back-shop-Half-shelf-subscription",
    operation:      "renew=",
    disabled:       false,
  },
  {
    name:           "Quarterly Back Shop Shelf Rental Subscription",
    description:    "Full shelf rental subscription automatically renews every month for 3 months.",
    amount:         38.0,
    quantity:       3,
    resource_class: "rental",
    plan_id:        "rental-quarterly-recurring-back-shop-shelf-subscription",
    operation:      "renew=",
    disabled:       false,
  },
]

RENTAL_INVOICE_OPTIONS.each do |opt|
  next if InvoiceOption.where(plan_id: opt[:plan_id]).exists?
  InvoiceOption.create!(opt)
  puts "  Created InvoiceOption: #{opt[:name]}"
end

tote_option       = InvoiceOption.find_by(plan_id: "rental-monthly-tote")
half_shelf_option = InvoiceOption.find_by(plan_id: "rental-quarterly-recurring-back-shop-Half-shelf-subscription")
full_shelf_option = InvoiceOption.find_by(plan_id: "rental-quarterly-recurring-back-shop-shelf-subscription")

puts "Seeding rental types..."

RENTAL_TYPES = [
  { display_name: "Storage Tote",   invoice_option: tote_option,       active: true },
  { display_name: "Full Shelf",     invoice_option: full_shelf_option,  active: true },
  { display_name: "Half Shelf",     invoice_option: half_shelf_option,  active: true },
  { display_name: "Parking Space",  invoice_option: nil,                active: true },
  { display_name: "Plot",           invoice_option: nil,                active: true },
]

RENTAL_TYPES.each do |rt|
  next if RentalType.where(display_name: rt[:display_name]).exists?
  RentalType.create!(
    display_name:      rt[:display_name],
    active:            rt[:active],
    invoice_option_id: rt[:invoice_option]&.id&.to_s
  )
  puts "  Created RentalType: #{rt[:display_name]}"
end

tote_type       = RentalType.find_by(display_name: "Storage Tote")
full_shelf_type = RentalType.find_by(display_name: "Full Shelf")
half_shelf_type = RentalType.find_by(display_name: "Half Shelf")
parking_type    = RentalType.find_by(display_name: "Parking Space")

puts "Seeding rental spots..."

RENTAL_SPOTS = [
  # Locker Room Totes
  { number: "LR-Tote-1", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
  { number: "LR-Tote-2", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
  { number: "LR-Tote-3", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
  { number: "LR-Tote-4", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
  { number: "LR-Tote-5", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
  { number: "LR-Tote-6", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
  # Back Shop Totes
  { number: "BS-Tote-1", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
  { number: "BS-Tote-2", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
  { number: "BS-Tote-3", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
  { number: "BS-Tote-4", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
  { number: "BS-Tote-5", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
  { number: "BS-Tote-6", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
  # Back Shop Full Shelves (parents)
  { number: "Shelf-1",   location: "Back Shop",   description: "Full Shelf", rental_type: full_shelf_type, requires_approval: false, parent_number: nil },
  { number: "Shelf-2",   location: "Back Shop",   description: "Full Shelf", rental_type: full_shelf_type, requires_approval: false, parent_number: nil },
  { number: "Shelf-3",   location: "Back Shop",   description: "Full Shelf", rental_type: full_shelf_type, requires_approval: false, parent_number: nil },
  { number: "Shelf-4",   location: "Back Shop",   description: "Full Shelf", rental_type: full_shelf_type, requires_approval: false, parent_number: nil },
  # Back Shop Half Shelves (children)
  { number: "Shelf-1a",  location: "Back Shop",   description: "Half Shelf (left)",  rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-1" },
  { number: "Shelf-1b",  location: "Back Shop",   description: "Half Shelf (right)", rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-1" },
  { number: "Shelf-2a",  location: "Back Shop",   description: "Half Shelf (left)",  rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-2" },
  { number: "Shelf-2b",  location: "Back Shop",   description: "Half Shelf (right)", rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-2" },
  { number: "Shelf-3a",  location: "Back Shop",   description: "Half Shelf (left)",  rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-3" },
  { number: "Shelf-3b",  location: "Back Shop",   description: "Half Shelf (right)", rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-3" },
  { number: "Shelf-4a",  location: "Back Shop",   description: "Half Shelf (left)",  rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-4" },
  { number: "Shelf-4b",  location: "Back Shop",   description: "Half Shelf (right)", rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-4" },
  # Parking (requires approval)
  { number: "Garage-1",  location: "Auto Bay",    description: "Auto Bay Overnight",     rental_type: parking_type, requires_approval: true, parent_number: nil },
  { number: "Parking-1", location: "Outside",     description: "Overnight Parking Spot", rental_type: parking_type, requires_approval: true, parent_number: nil },
]

RENTAL_SPOTS.each do |s|
  next if RentalSpot.where(number: s[:number]).exists?
  RentalSpot.create!(
    number:            s[:number],
    location:          s[:location],
    description:       s[:description],
    rental_type_id:    s[:rental_type]&.id&.to_s,
    requires_approval: s[:requires_approval],
    active:            true,
    parent_number:     s[:parent_number]
  )
  puts "  Created RentalSpot: #{s[:number]} (#{s[:location]})"
end

puts "Done. #{RentalType.count} types, #{RentalSpot.count} spots."
