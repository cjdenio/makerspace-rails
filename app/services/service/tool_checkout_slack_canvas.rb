module Service
  module ToolCheckoutSlackCanvas
    LOCK_TTL_SECONDS = 60

    class << self
      def sync!(shop)
        return if shop.slack_channel.blank?

        channel = Service::SlackChannelCache.lookup(shop.slack_channel)
        channel_id = channel&.dig(:id) || channel&.dig("id")
        channel_id ||= Service::SlackConnector.find_channel_id(shop.slack_channel)
        if channel_id.blank?
          report_failure(shop, StandardError.new("Slack channel not found"))
          return
        end

        with_canvas_lock(shop.id) do
          shop.reload
          canvas_id = shop.checkout_canvas_id.presence
          reused_canvas = canvas_id.present?
          canvas_id ||= create_and_cache_canvas!(shop, channel_id)

          begin
            publish!(canvas_id, shop, channel_id)
          rescue Slack::Web::Api::Errors::CanvasNotFound,
                 Slack::Web::Api::Errors::CanvasDeleted
            raise unless reused_canvas

            shop.set(checkout_canvas_id: nil)
            canvas_id = create_and_cache_canvas!(shop, channel_id)
            publish!(canvas_id, shop, channel_id)
          end
        end
      end

      def canvas_markdown(shop, channel_id: nil)
        tools = Tool.where(shop_id: shop.id, :disabled.ne => true)
          .order_by(name: :asc).to_a
        lines = [
          "# #{escape_markdown(shop.name)} Checkouts",
          "",
          "Current tool checkouts in #{shop_reference(shop, channel_id)}",
          ""
        ]
        # Slack Canvas markdown does not support document-fragment link targets.
        # Keep the tool index as plain text so one invalid link cannot reject the
        # entire canvas update.
        tools.each { |tool| lines << "- #{escape_markdown(tool.name)}" }

        tools.each do |tool|
          lines.concat(["", "---", "", "### #{escape_markdown(tool.name)}"])
          lines << '**Out of service - do not use.**' if tool.out_of_service?
          description = tool.description.to_s.strip
          wiki = "[#{escape_markdown(tool.name)} Wiki](#{tool.effective_wiki_url})"
          lines << [description, "(#{wiki})"].reject(&:blank?).join(" ")

          if tool.prerequisite_ids.present?
            prerequisites = tool.prerequisites.where(:disabled.ne => true)
              .order_by(name: :asc).pluck(:name)
            lines << "Pre-requisites: #{prerequisites.join(', ')}" if prerequisites.present?
          end

          lines << checkout_list_heading(tool)
          active_checkout_members(tool).each do |member|
            marker = checkout_approver?(member, tool) ? ":ballot_box_with_check:" : ":white_check_mark:"
            lines << "- #{marker} #{canvas_member_name(member)}"
          end
        end

        lines.concat(["", last_updated_line]).join("\n")
      end

      def sync_checkout!(checkout, action:)
        shop = checkout.tool.shop
        return sync!(shop) if shop.checkout_canvas_id.blank?

        with_canvas_lock(shop.id) do
          shop.reload
          canvas_id = shop.checkout_canvas_id.presence
          raise "Checkout canvas is not available" if canvas_id.blank?

          changes = action.to_s == "remove" ? removal_changes(canvas_id, checkout) : addition_changes(canvas_id, checkout)
          changes << timestamp_change(canvas_id)
          Service::SlackConnector.edit_canvas(canvas_id, changes)
        end
      rescue => error
        Rails.logger.warn(
          "[ToolCheckoutSlackCanvas] incremental edit failed; rebuilding " \
          "shop_id=#{shop.id} checkout_id=#{checkout.id} error=#{Service::SlackConnector.format_api_error(error)}"
        )
        sync!(shop)
      end

      def enqueue_for_members(member_ids)
        tool_ids = ToolCheckout.where(
          :member_id.in => Array(member_ids),
          revoked_at: nil
        ).distinct(:tool_id)
        Tool.where(:id.in => tool_ids).distinct(:shop_id).each do |shop_id|
          ToolCheckoutSlackCanvasSyncJob.perform_later(shop_id.to_s)
        end
      end

      def rebuild_all!
        Shop.all.each do |shop|
          next if shop.checkout_canvas_id.blank?

          sync!(shop)
        rescue => error
          report_failure(shop, error)
        end
      end

      def report_failure(shop, error)
        details = "shop: #{shop.name}, channel: #{shop.slack_channel}, " \
          "error: #{Service::SlackConnector.format_api_error(error)}"
        Rails.logger.error("[ToolCheckoutSlackCanvasError] #{details}")
        Service::AuditLogger.log(
          log_type: "portal",
          event_type: "checkout_canvas_sync_failed",
          resource_type: "Shop",
          resource_id: shop.id,
          message_details: ":warning: #{details}",
          slack_channel: Service::SlackConnector.logs_channel
        )
      end

      private

      def addition_changes(canvas_id, checkout)
        return [] unless checkout.member.active_unexpired?

        tool_section = lookup_section!(canvas_id, checkout_list_lookup_text(checkout.tool))
        [{
          operation: "insert_after",
          section_id: section_id(tool_section),
          document_content: { type: "markdown", markdown: checkout_line(checkout) }
        }]
      end

      def removal_changes(canvas_id, checkout)
        checkout_section = lookup_section!(canvas_id, checkout_line(checkout), require_unique: true)
        [{ operation: "delete", section_id: section_id(checkout_section) }]
      end

      def timestamp_change(canvas_id)
        timestamp_section = lookup_section!(canvas_id, "Last updated")
        {
          operation: "replace",
          section_id: section_id(timestamp_section),
          document_content: { type: "markdown", markdown: last_updated_line }
        }
      end

      def lookup_section!(canvas_id, text, section_types: nil, require_unique: false)
        sections = Service::SlackConnector.lookup_canvas_sections(
          canvas_id,
          contains_text: text,
          section_types: section_types
        )
        sections = Array(sections)
        if require_unique && sections.size != 1
          raise "Expected one Canvas section for #{text.inspect}, found #{sections.size}"
        end
        section = sections.first
        raise "Canvas section not found for #{text.inspect}" if section.nil? || section_id(section).blank?

        section
      end

      def section_id(section)
        return section.section_id if section.respond_to?(:section_id)
        return section.id if section.respond_to?(:id)

        section["section_id"] || section[:section_id] || section["id"] || section[:id]
      end

      def checkout_line(checkout)
        member = checkout.member
        marker = checkout_approver?(member, checkout.tool) ? ":ballot_box_with_check:" : ":white_check_mark:"
        "- #{marker} #{canvas_member_name(member)}"
      end

      def checkout_list_heading(tool)
        "**#{escape_markdown(checkout_list_lookup_text(tool))}**"
      end

      def checkout_list_lookup_text(tool)
        "Current checkouts for #{tool.name}:"
      end

      def last_updated_line
        "_Last updated #{Time.current.in_time_zone(ReservationService::ZONE).strftime('%B %-d, %Y at %H:%M %Z')}._"
      end

      def create_and_cache_canvas!(shop, channel_id)
        canvas_id = Service::SlackConnector.create_canvas(
          "#{shop.name} Checkouts",
          channel_id: channel_id
        )
        raise "Slack did not return a checkout canvas ID for #{shop.name}" if canvas_id.blank?

        Service::SlackConnector.set_canvas_user_access(
          canvas_id,
          Service::ReservationSlackCanvas.canvas_owner_slack_ids(shop),
          access_level: "owner"
        )
        shop.set(checkout_canvas_id: canvas_id)
        canvas_id
      end

      def publish!(canvas_id, shop, channel_id)
        Service::SlackConnector.set_canvas_channel_access(canvas_id, channel_id) if channel_id.present?
        Service::SlackConnector.replace_canvas(
          canvas_id,
          canvas_markdown(shop, channel_id: channel_id)
        )
      end

      def shop_reference(shop, channel_id)
        return "![](##{channel_id})" if channel_id.present?
        shop.slack_channel.presence || escape_markdown(shop.name)
      end

      def active_checkout_members(tool)
        member_ids = ToolCheckout.where(tool_id: tool.id, revoked_at: nil).pluck(:member_id)
        Member.where(:id.in => member_ids).to_a.select(&:active_unexpired?)
          .sort_by { |member| [member.lastname.to_s.downcase, member.firstname.to_s.downcase] }
      end

      def checkout_approver?(member, tool)
        member.manages_shop?(tool.shop) ||
          CheckoutApprover.find_by(member_id: member.id)&.can_approve_tool?(tool)
      end

      def canvas_member_name(member)
        slack_name = SlackUser.find_by(member_id: member.id)&.name
        sanitize_member_name(slack_name).presence || sanitize_member_name(member.fullname)
      end

      def sanitize_member_name(value)
        value.to_s
          .gsub(/[^\x00-\x7F]/, "")
          .gsub(/[\\`*_{}\[\]()#+\-.!|>@]/, "")
          .gsub(/\s+/, " ")
          .strip
      end

      def escape_markdown(value)
        value.to_s.gsub(/([\\`*_{}\[\]()#+.!-])/) { |match| "\\#{match}" }
      end

      def with_canvas_lock(shop_id)
        key = "tool_checkout_canvas_lock/shop/#{shop_id}"
        token = SecureRandom.uuid
        acquired = REDIS.set(key, token, nx: true, ex: LOCK_TTL_SECONDS)
        raise "Slack checkout canvas synchronization is busy" unless acquired

        yield
      ensure
        REDIS.eval(
          "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
          keys: [key], argv: [token]
        ) if key && token
      end
    end
  end
end
