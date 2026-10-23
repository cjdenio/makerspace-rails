require 'rails_helper'

RSpec.describe CheckoutRequiredSheet do
  let(:url) { 'HTTPS://MEMBERS.EXAMPLE.ORG/L23456789AB' }
  def sheet(**options)
    described_class.new(name: 'Bandsaw & <Planer>', channel: '###shop-woodworking', short_url: url, **options).to_svg
  end
  def xml(svg)
    Nokogiri::XML(svg) { |config| config.strict.nonet }
  end

  it 'produces standalone Letter landscape XML with two identical vector signs' do
    document = xml(sheet)
    expect(document.root.namespace.href).to eq('http://www.w3.org/2000/svg')
    expect(%w[width height viewBox].map { |attribute| document.root[attribute] }).to eq(['11in', '8.5in', '0 0 1100 850'])
    signs = document.xpath('//*[local-name()="g" and @class="checkout-sign"]')
    expect(signs.length).to eq(2)
    expect(signs.map { |sign| sign['transform'] }).to eq(['translate(25 25)', 'translate(25 437.5)'])
    expect(signs[0].inner_html).to eq(signs[1].inner_html)
    expect(signs.first.text).to include('Operation & Safety', 'Checkout', 'Required', 'Bandsaw & <Planer>', 'SLACK: #shop-woodworking', 'Scan QR to', 'Request Checkout')
    expect(document.xpath('//*[local-name()="script" or local-name()="image" or local-name()="foreignObject"]')).to be_empty
    expect(document.xpath('//@href | //@*[starts-with(local-name(), "on")]')).to be_empty
    expect(document.xpath('//@id').map(&:value).uniq.length).to eq(document.xpath('//@id').length)
    expect(document.xpath('//*[local-name()="path"]').length).to be > 2
    qrs = document.xpath('//*[@class="shortcode-qr"]')
    expect(qrs.length).to eq(2)
    expect(%w[width height].map { |attribute| qrs.first[attribute] }).to eq(%w[230 230])
    expected_size = RQRCode::QRCode.new(url, mode: :alphanumeric).modules.length + 8
    expect(qrs.first['viewBox']).to eq("0 0 #{expected_size} #{expected_size}")
  end

  it 'centers one unchanged-size sign when one copy is requested' do
    signs = xml(sheet(copies: 1)).xpath('//*[@class="checkout-sign"]')
    expect(signs.length).to eq(1)
    expect(signs.first['transform']).to eq('translate(25 231.25)')
    expect(signs.first.inner_html).to eq(xml(sheet).at_xpath('//*[@class="checkout-sign"]').inner_html)
  end

  it 'omits a missing channel and safely fits long names' do
    name = ('Wide Workshop & Tool <Name> ' * 8).strip
    svg = described_class.new(name: name, channel: nil, short_url: url).to_svg
    document = xml(svg)
    sign = document.at_xpath('//*[@class="checkout-sign"]')
    expect(sign.text).not_to include('SLACK:')
    expect(sign.xpath('./*[local-name()="text" and @textLength="1000"]').length).to eq(2)
    expect(document.xpath('//*[local-name()="Name"]')).to be_empty
  end

  it 'centers equal-size name and footer text around the larger heading and round logo' do
    document = xml(sheet)
    sign = document.at_xpath('//*[@class="checkout-sign"]')
    %w[resource-name shop-channel].each do |css_class|
      label = sign.at_xpath(".//*[@class='#{css_class}']")
      expect(%w[x font-size text-anchor font-weight].map { |key| label[key] }).to eq(%w[525 26 middle normal])
    end
    heading = sign.at_xpath('.//*[@class="safety-heading"]')
    expect(%w[x font-size text-anchor].map { |key| heading[key] }).to eq(%w[525 36 middle])
    logo = sign.at_xpath('.//*[@class="makerspace-logo"]')
    expect(%w[width height].map { |key| logo[key] }).to eq(%w[240 240])
    expect(logo.at_xpath('.//*[local-name()="circle"]')['fill']).to eq('#d22429')
    expect(logo.at_xpath('.//*[local-name()="path"]')['fill']).to eq('#fff')
  end

  it 'preserves unbroken names and escaped long channels without changing their font size' do
    name = 'W' * 160
    channel = 'woodworking-&-<tools>-' * 8
    document = xml(described_class.new(name: name, channel: channel, short_url: url).to_svg)
    labels = document.at_xpath('//*[@class="checkout-sign"]').xpath('.//*[@class="resource-name" or @class="shop-channel"]')
    expect(labels.first(2).map(&:text).join).to eq(name)
    expect(labels.last.text).to eq("SLACK: ##{channel}")
    expect(labels.map { |label| label['font-size'] }.uniq).to eq(['26'])
    expect(labels.map { |label| label['textLength'] }.uniq).to eq(['1000'])
    expect(document.xpath('//*[local-name()="tools"]')).to be_empty
  end

  it 'rejects unsupported copy counts' do
    expect { sheet(copies: 3) }.to raise_error(ArgumentError)
  end
end
