# Colors the public storage map draws, kept in step with the portal's map
# (src/ui/toolCheckouts/locationKinds.ts in the React app) so a scanned tool
# page looks like the shop's own map: the shop's calendar color on its areas,
# a fixed color per kind for anything nested inside, and one reserved color for
# anything holding a tool.
module MapColors
  KIND = {
    "area" => "#1976d2",
    "cabinet" => "#6d4c41",
    "shelf" => "#8e24aa",
    "drawer" => "#00897b",
    "table" => "#f9a825",
    "bin" => "#9e9d24"
  }.freeze
  FALLBACK_NESTED = "#e65100".freeze
  TOOL_MARKER = "#2e7d32".freeze
  DEFAULT_SHOP = "#1976d2".freeze

  # The shop's calendar color, from the same palette the portal uses. Never
  # calls Google from a public request (see cached_calendar_color).
  def self.shop(color_id)
    Service::GoogleWorkspace.cached_calendar_color(color_id) || DEFAULT_SHOP
  end

  def self.for_location(location, shop_color:, holds_tool:)
    return shop_color if location.parent_id.nil?
    return TOOL_MARKER if holds_tool

    KIND[location.kind.to_s] || FALLBACK_NESTED
  end
end
