class SlackReservationModal
  class << self
    def build(shop, member)
      tools = Tool.where(shop_id: shop.id, reservable: true, :disabled.ne => true).order_by(name: :asc).to_a
      raise ::Error::UnprocessableEntity.new("This shop has more than 100 reservable tools; use the portal") if tools.length > 100
      raise ::Error::UnprocessableEntity.new("This shop has no reservable resources") unless shop.reservable || tools.present?

      scope_options = []
      scope_options << option("Entire shop", "shop") if shop.reservable
      scope_options << option("One or more tools", "tools") if tools.present?

      {
        type: "modal",
        callback_id: "reservation_submit",
        private_metadata: { shop_id: shop.id.to_s, member_id: member.id.to_s }.to_json,
        title: plain("Reserve #{shop.name}".first(24)),
        submit: plain("Reserve"),
        close: plain("Cancel"),
        blocks: [
          input("title", "title", "Title", { type: "plain_text_input" }),
          input("scope", "scope", "Reserve", {
            type: "radio_buttons",
            options: scope_options,
            initial_option: scope_options.first
          }),
          {
            type: "input",
            block_id: "tools",
            optional: true,
            label: plain("Tools"),
            element: {
              type: "multi_static_select",
              action_id: "tools",
              placeholder: plain("Select tools"),
              options: tools.map { |tool| option(tool.name, tool.id.to_s) }
            }
          },
          input("date", "date", "Date", {
            type: "datepicker",
            initial_date: Time.current.in_time_zone(ReservationService::ZONE).to_date.iso8601
          }),
          input("start_time", "start_time", "Start time", {
            type: "timepicker",
            initial_time: next_half_hour.strftime("%H:%M")
          }),
          input("end_time", "end_time", "End time", {
            type: "timepicker",
            initial_time: (next_half_hour + 1.hour).strftime("%H:%M")
          })
        ]
      }
    end

    private

    def plain(text)
      { type: "plain_text", text: text, emoji: true }
    end

    def option(text, value)
      { text: plain(text.first(75)), value: value }
    end

    def input(block_id, action_id, label, element)
      {
        type: "input",
        block_id: block_id,
        label: plain(label),
        element: element.merge(action_id: action_id)
      }
    end

    def next_half_hour
      now = Time.current.in_time_zone(ReservationService::ZONE)
      rounded_minute = now.min < 30 ? 30 : 0
      result = now.change(min: rounded_minute, sec: 0)
      rounded_minute.zero? ? result + 1.hour : result
    end
  end
end
