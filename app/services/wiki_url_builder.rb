module WikiUrlBuilder
  DEFAULT_BASE_URL = "https://wiki.manchestermakerspace.org".freeze

  def self.base_url
    ENV["WIKI_URL"].to_s.strip.presence&.sub(%r{/+\z}, "") || DEFAULT_BASE_URL
  end

  def self.shop_url(shop_name)
    "#{base_url}/workshops/#{slug(shop_name)}"
  end

  def self.tool_url(shop_name, tool_name)
    "#{shop_url(shop_name)}##{slug(tool_name)}"
  end

  def self.slug(value)
    value.to_s.parameterize
  end
end
