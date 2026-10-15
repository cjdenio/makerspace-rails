require 'nokogiri'
require 'rqrcode'

# A self-contained Letter sheet. Coordinates are hundredths of an inch.
# Only trusted, repository-owned logo geometry is imported; all dynamic text
# is added as XML text nodes, never interpolated into markup.
class CheckoutRequiredSheet
  SVG_NS = 'http://www.w3.org/2000/svg'.freeze
  MARGIN = 25
  SIGN_WIDTH = 1050
  SIGN_HEIGHT = 387.5
  SIGN_GAP = 25
  attr_reader :channel

  def initialize(name:, channel:, short_url:, copies: 2)
    raise ArgumentError, 'copies must be 1 or 2' unless [1, 2].include?(copies)
    @copies = copies
    @name = name.to_s.gsub(/[[:space:]]+/, ' ').strip
    @channel = channel.to_s.strip.sub(/\A#+/, '').strip
    @short_url = short_url
  end

  def to_svg
    document = Nokogiri::XML::Document.new
    root = node(document, 'svg', xmlns: SVG_NS, width: '11in', height: '8.5in', viewBox: '0 0 1100 850', version: '1.1')
    document.root = root
    root.add_child(node(document, 'title', {}, "Checkout Required — #{@name}"))
    root.add_child(node(document, 'rect', width: 1100, height: 850, fill: '#fff'))

    # Build once and duplicate, so both signs have exactly the same content.
    sign = node(document, 'g', 'font-family': 'Arial, Helvetica, sans-serif', fill: '#000')
    name_lines.each_with_index do |line, index|
      sign.add_child(text(document, line, x: SIGN_WIDTH / 2, y: 26 + index * 30, size: 26, width: 1000, css_class: 'resource-name'))
    end
    logo = Nokogiri::XML(File.read(Rails.root.join('app/assets/images/CheckoutRoundLogo.svg'))) { |config| config.strict.nonet }.root
    logo['x'], logo['y'], logo['width'], logo['height'] = '10', '80', '240', '240'
    logo['class'] = 'makerspace-logo'
    sign.add_child(logo)
    sign.add_child(text(document, 'Operation & Safety', x: SIGN_WIDTH / 2, y: 98, size: 36, css_class: 'safety-heading'))
    sign.add_child(text(document, 'Checkout', x: SIGN_WIDTH / 2, y: 205, size: 100, weight: 'bold', color: '#800000'))
    sign.add_child(text(document, 'Required', x: SIGN_WIDTH / 2, y: 325, size: 100, weight: 'bold', color: '#800000'))

    mode = @short_url.match?(/\A[0-9A-Z $%*+\-.\/:]+\z/) ? :alphanumeric : :byte_8bit
    qr = RQRCode::QRCode.new(@short_url, mode: mode)
    size = qr.modules.length + 8
    qr_svg = Nokogiri::XML(qr.as_svg(color: '000', fill: 'fff', module_size: 1,
      offset: 4, standalone: true, use_path: true, viewbox: true)) { |config| config.strict.nonet }.root
    qr_svg['x'], qr_svg['y'], qr_svg['width'], qr_svg['height'] = '810', '80', '230', '230'
    qr_svg['viewBox'] = "0 0 #{size} #{size}"
    qr_svg['class'] = 'shortcode-qr'
    sign.add_child(qr_svg)
    sign.add_child(text(document, 'Scan QR to', x: 925, y: 330, size: 18))
    sign.add_child(text(document, 'Request Checkout', x: 925, y: 350, size: 18))
    unless channel.empty?
      sign.add_child(text(document, "SLACK: ##{channel}", x: SIGN_WIDTH / 2, y: 380, size: 26, width: 1000, css_class: 'shop-channel'))
    end
    (@copies == 1 ? [(850 - SIGN_HEIGHT) / 2] : [MARGIN, MARGIN + SIGN_HEIGHT + SIGN_GAP]).each do |y|
      copy = sign.dup
      copy['class'] = 'checkout-sign'
      copy['transform'] = "translate(#{MARGIN} #{y})"
      root.add_child(copy)
    end
    document.to_xml(encoding: 'UTF-8')
  end

  private

  def node(document, tag, attributes = {}, content = nil)
    element = Nokogiri::XML::Node.new(tag, document)
    attributes.each { |key, value| element[key.to_s] = value.to_s }
    element.content = content unless content.nil?
    element
  end

  def text(document, value, x:, y:, size:, width: nil, weight: 'normal', color: '#000', css_class: nil)
    attributes = { x: x, y: y, 'font-size': size, 'text-anchor': 'middle', 'font-weight': weight, fill: color }
    attributes[:class] = css_class if css_class
    # Conservative fit bound for the standard sans-serif stack, including long
    # unbroken channel names. Short labels retain their natural letter spacing.
    if width && value.length * size > width
      attributes[:textLength] = width
      attributes[:lengthAdjust] = 'spacingAndGlyphs'
    end
    node(document, 'text', attributes, value)
  end

  def name_lines
    return [@name] if @name.length <= 60
    midpoint = @name.length / 2
    spaces = @name.enum_for(:scan, / /).map { Regexp.last_match.begin(0) }
    split = spaces.min_by { |position| (position - midpoint).abs } || midpoint
    [@name[0...split].strip, @name[split..].strip]
  end
end
