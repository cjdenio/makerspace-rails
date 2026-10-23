class SlackCheckoutRequestModal
  MAX_OPTIONS = 100

  class << self
    def build(shop, member, response_url: nil)
      tools = eligible_tools(shop, member) + CheckoutInteractionQuery.new(member: member, shop: shop).requestable_groups
      raise ::Error::UnprocessableEntity.new("This shop has no tools you can request") if tools.empty?
      raise ::Error::UnprocessableEntity.new("This shop has more than 100 eligible tools; use the Member Portal") if tools.length > MAX_OPTIONS

      {
        type: "modal",
        callback_id: "checkout_request_submit",
        private_metadata: { shop_id: shop.id.to_s, response_url: response_url }.compact.to_json,
        title: plain("Request a checkout"),
        submit: plain("Request"),
        close: plain("Cancel"),
        blocks: [
          {
            type: "input", block_id: "tool", label: plain("Tool"),
            element: {
              type: "static_select", action_id: "tool", placeholder: plain("Select a tool"),
              options: tools.map { |tool| option(tool) }
            }
          },
          {
            type: "input", block_id: "note", optional: true, label: plain("Note"),
            element: { type: "plain_text_input", action_id: "note", max_length: 128 }
          }
        ]
      }
    end

    def eligible_tools(shop, member)
      CheckoutInteractionQuery.new(member: member, shop: shop).requestable_tools
    end

    def eligible?(member, tool)
      tool.present? && ToolCheckoutRequestEligibility.new(member: member, tool: tool).eligible?
    end

    private

    def plain(text)
      { type: "plain_text", text: text, emoji: true }
    end

    def option(tool)
      group = tool.is_a?(ToolGroup)
      { text: plain("#{group ? ':linked_paperclips: ' : ''}#{tool.name}".first(75)), value: "#{group ? 'group:' : ''}#{tool.id}" }
    end
  end
end
