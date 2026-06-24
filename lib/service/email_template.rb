module Service
  class EmailTemplate
    # Map of email template names to their ENV var keys
    TEMPLATE_ENV_KEYS = {
      welcome_email:                  "EMAIL_WELCOME_ID",
      welcome_email_manual_register:  "EMAIL_WELCOME_MANUAL_ID",
      member_registered:              "EMAIL_MEMBER_REGISTERED_ID",
      password_changed:               "EMAIL_PASSWORD_CHANGED_ID",
      new_subscription:               "EMAIL_NEW_SUBSCRIPTION_ID",
      failed_payment:                 "EMAIL_FAILED_PAYMENT_ID",
      canceled_subscription:          "EMAIL_CANCELED_SUBSCRIPTION_ID",
    }.freeze

    # Fetch a Google Doc template and substitute variables.
    # Returns nil if no file ID configured or fetch fails — caller should fall back to .html.erb
    def self.render(template_name, variables = {})
      file_id = ENV[TEMPLATE_ENV_KEYS[template_name.to_sym]]
      return nil if file_id.blank?

      begin
        drive = ::Service::GoogleDrive.load_gdrive
        buffer = StringIO.new
        drive.export_file(file_id, "text/html", download_dest: buffer)
        content = buffer.string
        body = extract_body(content)
        substitute(body, variables)
      rescue => e
        Rails.logger.error("[EmailTemplate] Failed to fetch template '#{template_name}' (#{file_id}): #{e.message}")
        nil
      end
    end

    private

    # Extract just the body content from Google's exported HTML
    def self.extract_body(html)
      match = html.match(/<body[^>]*>(.*?)<\/body>/mi)
      match ? match[1].strip : html
    end

    # Replace {{variable}} placeholders with values
    def self.substitute(content, variables)
      variables.each do |key, value|
        content = content.gsub("{{#{key}}}", value.to_s)
      end
      content
    end
  end
end
