class SlackCheckoutModal
  CALLBACK_ID = "checkout_modal".freeze
  MENU = "checkout_menu".freeze
  SHOP = "checkout_shop".freeze
  TOOL = "checkout_tool".freeze
  REQUEST = "checkout_request".freeze
  CHECKOUT = "checkout_checkout".freeze
  NOTE = "checkout_note".freeze
  BACK = "checkout_back".freeze
  EDIT = "checkout_edit_note".freeze
  CANCEL = "checkout_cancel_request".freeze
  APPROVE = "checkout_approve_request".freeze
  DECLINE = "checkout_decline_request".freeze
  REASON = "checkout_reason".freeze
  VOLUNTEER = "checkout_volunteer".freeze
  APPROVE_VOLUNTEER = "checkout_approve_volunteer".freeze
  DECLINE_VOLUNTEER = "checkout_decline_volunteer".freeze
  CHOICES = [["View my checkouts", "active"], ["Request a checkout", "request_tools"],
             ["Volunteer to do checkouts", "volunteer"], ["View open requests", "requests"]].freeze
  METADATA_KEYS = %w[member_id shop_id response_url slack_user_id step record_id group_revision].freeze

  # Integrity-protected context, not an authorization cache. A client cannot
  # replace the shop or workflow step; the workflow still reloads every record.
  def self.encode_metadata(metadata)
    Rails.application.message_verifier("slack_checkout_modal").generate(
      metadata.slice(*METADATA_KEYS), purpose: "checkout", expires_in: 1.hour)
  end

  def self.decode_metadata(value)
    Rails.application.message_verifier("slack_checkout_modal").verified(value, purpose: "checkout")
  end

  def self.membership_error(member)
    return "Link your Slack account to a Member Portal account before using /checkout." unless member
    case member.status
    when "pending" then nil
    when "revoked" then "Your membership is revoked. Contact the makerspace before using checkouts."
    when "suspended" then "Your membership is suspended. Contact the makerspace before using checkouts."
    when "inactive" then "Your membership is inactive. Activate it before using checkouts."
    when "activeMember"
      "Your membership has expired. Renew it before using checkouts." unless member.active_unexpired?
    else "Your membership is not eligible for checkouts. Contact the makerspace."
    end
  end

  def self.entry(member:, shop: nil, response_url: nil, slack_user_id:)
    metadata = { "member_id" => member.id.to_s, "shop_id" => shop&.id&.to_s,
      "response_url" => response_url, "slack_user_id" => slack_user_id, "step" => "menu" }.compact
    new(member: member, shop: shop, metadata: metadata).build
  end

  def initialize(member: nil, shop: nil, metadata: {}, tools: [], requests: [], volunteer_requests: [], checkouts: [],
                 tool: nil, request: nil, volunteer_request: nil, checkout: nil, can_approve: false, alert: nil)
    @member, @shop, @metadata = member, shop, metadata.slice(*METADATA_KEYS)
    @tools, @requests, @volunteer_requests, @checkouts = tools, requests, volunteer_requests, checkouts
    @tool, @request, @volunteer_request, @checkout, @can_approve, @alert = tool, request, volunteer_request, checkout, can_approve, alert
  end

  def build
    @blocks = []
    @submit = nil
    section(@shop.name) if @shop
    section(@alert) if @alert
    case @metadata.fetch("step", "menu")
    when "menu"
      shop_selector unless @shop
      selector(MENU, "What would you like to do?", CHOICES)
    when /\Ashop_(active|request_tools|requests|volunteer)\z/
      shop_selector
    when "request_tools"
      selector(TOOL, "Tool", @tools.map { |tool| tool_option(tool) })
    when "request_new"
      section("Request a checkout on #{@tool.name}")
      note_input
      @submit = "Request"
    when "volunteer"
      selector(TOOL, "Checked-out tool", @tools.map { |tool| tool_option(tool) })
    when "volunteer_confirm"
      section("Volunteer to approve checkouts for #{@tool.name}")
      note_input
      @submit = "Volunteer"
    when "requests"
      rows = (@volunteer_requests + @requests).sort_by { |row| [row.tool_group_id ? 1 : 0, row.target.name.downcase] }
      selector(REQUEST, "Open request", rows.map do |row|
        volunteer = row.is_a?(CheckoutApproverRequest)
        ["#{volunteer ? 'VOLUNTEER: ' : ''}#{row.tool_group_id ? ':linked_paperclips: ' : ''}#{row.target.name} — #{row.member.fullname}", "#{volunteer ? 'volunteer:' : ''}#{row.id}"]
      end)
    when "volunteer_detail"
      section("Volunteer: #{@volunteer_request.member.fullname}")
      section("Tool: #{@volunteer_request.target.name}")
      section("Requested: #{@volunteer_request.request_date&.iso8601}")
      section("Checked out: #{volunteer_checkout_date}")
      section("Joined makerspace: #{member_join_date(@volunteer_request.member)}")
      section("Note: #{@volunteer_request.note}") if @volunteer_request.note.present?
      actions([["Approve volunteer", APPROVE_VOLUNTEER], ["Decline volunteer", DECLINE_VOLUNTEER]])
    when "volunteer_approve", "volunteer_decline"
      decision = @metadata["step"] == "volunteer_approve" ? "Approve" : "Decline"
      section("#{decision} #{@volunteer_request.member.fullname}'s request for #{@volunteer_request.target.name}?")
      note_input
      @submit = decision
    when "request_detail"
      request_details
      buttons = []
      buttons += [["Edit note", EDIT], ["Cancel request", CANCEL]] if @request.member_id == @member.id
      if @can_approve && @request.member_id != @member.id
        buttons << ["Approve", APPROVE]
        buttons << ["Decline", DECLINE]
      end
      actions(buttons) if buttons.any?
    when "request_edit"
      request_details
      note_input(@request.note)
      @submit = "Save note"
    when "request_decline"
      request_details
      reason_input
      @submit = "Decline request"
    when "request_cancel", "request_approve"
      request_details
      @submit = @metadata["step"] == "request_cancel" ? "Cancel request" : "Approve"
      section("Select #{@submit} to confirm.")
    when "active"
      selector(CHECKOUT, "Your active checkout", @checkouts.map { |row| [row.tool.name, row.id.to_s] })
    when "checkout_detail"
      CheckoutDisplay.details(@checkout).each do |line|
        if line.start_with?("Wiki: ")
          url = line.delete_prefix("Wiki: ")
          # Encode link delimiters instead of accepting user-provided mrkdwn.
          url = url.gsub('|', '%7C').gsub('>', '%3E').gsub('<', '%3C').gsub('&', '&amp;')
          if url.length <= 2800 && PublicCatalog.safe_url(line.delete_prefix("Wiki: "))
            @blocks << { type: "section", text: { type: "mrkdwn", text: "<#{url}|Wiki>", verbatim: true } }
          else
            section("Use the Member Portal to open this tool's wiki link.")
          end
        else
          section(line)
        end
      end
    end
    actions([["Go back", BACK]], block_id: "checkout_navigation") unless @metadata["step"] == "menu"
    view = { type: "modal", callback_id: CALLBACK_ID, private_metadata: self.class.encode_metadata(@metadata),
      title: plain("Safety checkouts"), close: plain("Close"), blocks: @blocks }
    view[:submit] = plain(@submit) if @submit
    view
  end

  private

  def plain(text)
    { type: "plain_text", text: text.to_s.first(3000) }
  end

  def section(text)
    @blocks << { type: "section", text: plain(text) }
  end

  def shop_selector
    shops = CheckoutInteractionQuery.new(member: @member).enabled_shops
    selector(SHOP, "Shop", shops.map { |shop| [shop.name, shop.id.to_s] })
  end

  def selector(id, label, choices)
    return section("No #{label.downcase} options are currently available.") if choices.empty?
    if choices.length > 100
      return section("There are more than 100 #{label.downcase} options. Use the Member Portal to view them all.")
    end
    # Navigation selectors must not be input blocks: Slack requires a submit
    # button for any view containing inputs, and these steps only navigate.
    @blocks << { type: "section", block_id: id, text: plain(label),
      accessory: { type: "static_select", action_id: "#{id}_select", placeholder: plain("Select an option"),
        options: choices.map { |name, value| { text: plain(name.to_s.first(75)), value: value } } } }
  end

  def note_input(value = nil)
    element = { type: "plain_text_input", action_id: NOTE, max_length: 128 }
    element[:initial_value] = value if value.present?
    @blocks << { type: "input", block_id: NOTE, optional: true, label: plain("Note"), element: element }
  end

  # A decline needs a reason, which the requester is shown, so the input is required.
  def reason_input
    @blocks << { type: "input", block_id: REASON, optional: false, label: plain("Reason (shown to the requester)"),
      element: { type: "plain_text_input", action_id: REASON, max_length: CheckoutRequestDecision::REASON_MAX } }
  end

  def request_details
    section("#{@request.tool_group_id ? ':linked_paperclips: Group' : 'Tool'}: #{@request.target.name}")
    if @request.tool_group
      review = ToolGroupCheckout.review(member: @request.member, group: @request.tool_group)
      @request.tool_group.included_tools.each do |tool|
        state = review[:held_tool_ids].include?(tool.id.to_s) ? 'Already held' : 'Will create checkout'
        section("#{tool.name}: #{state}")
        section("Wiki: #{tool.effective_wiki_url}") if tool.effective_wiki_url.present?
        section("Drive: https://drive.google.com/drive/folders/#{tool.gdrive_id}") if tool.gdrive_id.present?
        section(tool.effective_requestor_annotation) if tool.effective_requestor_annotation.present?
        section(tool.notes) if tool.notes.present? && tool.notes_visible_to?(@member)
      end
      section("Prerequisites: #{Tool.where(:id.in => review[:prerequisite_ids]).map(&:name).join(', ')}")
    end
    section("Requested: #{@request.request_date&.iso8601}")
    if @request.member_id != @member.id
      section("Member: #{@request.member.fullname}")
      section("Shop: #{@shop.name}")
    end
    section(@request.note) if @request.note.present?
  end

  def volunteer_checkout_date
    @volunteer_request.checkout_completed_on
  end

  def member_join_date(member)
    member.startDate.respond_to?(:to_date) ? member.startDate.to_date.iso8601 : member.startDate.to_s.presence || "Unknown"
  end

  def actions(buttons, block_id: "checkout_actions")
    @blocks << { type: "actions", block_id: block_id,
      elements: buttons.map { |label, id| { type: "button", action_id: id, text: plain(label), value: id } } }
  end

  def tool_option(tool)
    tool.is_a?(ToolGroup) ? [":linked_paperclips: #{tool.name}", "group:#{tool.id}"] : [tool.name, tool.id.to_s]
  end
end
