namespace :shortcodes do
  desc "Repair, create and verify the full unique indexes required for short URLs"
  task ensure_indexes: :environment do
    Shortcode.ensure_indexes!
    ShortUrl.verify_indexes!(force: true)
    puts "Shortcode unique indexes verified"
  end
end

# Prerequisites run before Mongoid attempts to create same-named indexes with
# incompatible options. An after-action cannot repair an IndexOptionsConflict.
Rake::Task["db:mongoid:create_indexes"].enhance(["shortcodes:ensure_indexes"])
