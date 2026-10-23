# Run with bundle exec rails runner scripts/ci/checkout-sheet-fixtures.rb.
# Uses a fixed example URL; no allocation or database mutation is performed.
require 'fileutils'
destination = Rails.root.join('tmp/checkout-sheets')
FileUtils.mkdir_p(destination)
samples = {
  'double' => {}, 'single' => { copies: 1 },
  'long' => { name: 'Wide Workshop & Tool <Name> ' * 8 },
  'long-channel' => { channel: 'shop-woodworking-metalworking-electronics-automotive-lasers-3d-printing-and-fabrication' },
  'unbroken' => { name: 'W' * 160, channel: 'shop-&-<tools>-' * 8 },
  'blank' => { channel: nil }
}
samples.to_a.each do |name, options|
  samples["#{name}-single"] = options.merge(copies: 1) unless %w[double single].include?(name)
end
samples.each do |name, options|
  sheet = CheckoutRequiredSheet.new(**{
    name: 'Woodworking Bandsaw', channel: 'shop-woodworking',
    short_url: 'HTTPS://MEMBERS.EXAMPLE.ORG/L23456789AB'
  }.merge(options))
  File.write(destination.join("#{name}.svg"), sheet.to_svg)
end
puts "Wrote #{samples.length} SVG fixtures to #{destination}"
