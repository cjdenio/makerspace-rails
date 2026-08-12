require 'erb'
require 'cgi'
require 'json'
require 'net/http'
require 'signet/errors'
require 'stringio'
require 'time'
require 'uri'

module Service
  class EmailTemplate
    class TemplateError < StandardError; end
    class MissingEnvironmentVariable < TemplateError; end
    class InvalidTemplate < TemplateError; end
    class PermissionError < TemplateError; end

    CACHE_VERSION = 1
    CACHE_PREFIX = "external_template:v#{CACHE_VERSION}".freeze
    PLACEHOLDER_PATTERN = /\{\{\s*([a-z][a-z0-9_]*)\s*\}\}/i.freeze

    COMMON_PLACEHOLDERS = %w[
      first_name
      last_name
      full_name
      email
      member_id
      join_date
      expiration_date
      slack_username
      slack_id
      profile_url
      portal_url
      base_url
      open_house_schedule
    ].freeze

    # This is the centralized registry of every Google-hosted editable template.
    # New variables must follow EMAIL_<PURPOSE>_ID or DOC_<PURPOSE>_ID.
    TEMPLATE_ENV_KEYS = {
      password_changed:                    'EMAIL_PASSWORD_CHANGED_ID',
      welcome_email:                       'EMAIL_WELCOME_ID',
      welcome_email_manual_register:       'EMAIL_WELCOME_MANUAL_ID',
      member_registered:                   'EMAIL_MEMBER_REGISTERED_ID',
      new_subscription:                    'EMAIL_NEW_SUBSCRIPTION_ID',
      failed_payment:                      'EMAIL_FAILED_PAYMENT_ID',
      canceled_subscription:               'EMAIL_CANCELED_SUBSCRIPTION_ID',
      household_disbanded_primary_email:   'EMAIL_HOUSEHOLD_DISBANDED_PRIMARY_ID',
      household_disbanded_secondary_email: 'EMAIL_HOUSEHOLD_DISBANDED_SECONDARY_ID',
      reservation_reminder:                'DOC_RESERVATION_REMINDER_ID',
      volunteer_credit_awarded:            'DOC_VOLUNTEER_CREDIT_AWARDED_ID',
      volunteer_credit_discount_earned:    'DOC_VOLUNTEER_CREDIT_DISCOUNT_EARNED_ID',
      volunteer_credit_discount_progress:  'DOC_VOLUNTEER_CREDIT_DISCOUNT_PROGRESS_ID',
      volunteer_credit_reversed:           'DOC_VOLUNTEER_CREDIT_REVERSED_ID',
      volunteer_braintree_review:          'DOC_VOLUNTEER_BRAINTREE_REVIEW_ID',
      volunteer_discount_applied_member:   'DOC_VOLUNTEER_DISCOUNT_APPLIED_MEMBER_ID',
      volunteer_discount_applied_admin:    'DOC_VOLUNTEER_DISCOUNT_APPLIED_ADMIN_ID',
      volunteer_discount_no_subscription:  'DOC_VOLUNTEER_DISCOUNT_NO_SUBSCRIPTION_ID',
      volunteer_discount_error:            'DOC_VOLUNTEER_DISCOUNT_ERROR_ID',
      household_disbanded_primary:         'DOC_HOUSEHOLD_DISBANDED_PRIMARY_ID',
      household_disbanded_secondary:       'DOC_HOUSEHOLD_DISBANDED_SECONDARY_ID',
      household_disbanded_admin:           'DOC_HOUSEHOLD_DISBANDED_ADMIN_ID',
      member_review_orientation:           'DOC_MEMBER_REVIEW_ORIENTATION_ID',
      member_review_no_purchase:           'DOC_MEMBER_REVIEW_NO_PURCHASE_ID',
      member_review_paypal:                 'DOC_MEMBER_REVIEW_PAYPAL_ID',
      member_review_missing_contract:       'DOC_MEMBER_REVIEW_MISSING_CONTRACT_ID',
      member_review_expired_rental:         'DOC_MEMBER_REVIEW_EXPIRED_RENTAL_ID'
    }.freeze

    TEMPLATE_DEFINITIONS = {
      password_changed: { format: :html, placeholders: %w[member_firstname url], fallback: 'member_mailer/password_changed', default: 'external_templates/password_changed_default' },
      welcome_email: { format: :html, placeholders: %w[url], fallback: 'member_mailer/welcome_email', default: 'external_templates/welcome_email_default' },
      welcome_email_manual_register: { format: :html, placeholders: %w[member_email reset_url], fallback: 'member_mailer/welcome_email_manual_register', default: 'external_templates/welcome_email_manual_register_default' },
      member_registered: { format: :html, placeholders: %w[member_name], fallback: 'member_mailer/member_registered', default: 'external_templates/member_registered_default' },
      new_subscription: { format: :html, placeholders: %w[member_name friendly_type quantity next_billing_date url], fallback: 'billing_mailer/new_subscription', default: 'external_templates/new_subscription_default' },
      failed_payment: { format: :html, placeholders: %w[member_name friendly_type error_status url], fallback: 'billing_mailer/failed_payment', default: 'external_templates/failed_payment_default' },
      canceled_subscription: { format: :html, placeholders: %w[member_name friendly_type url], fallback: 'billing_mailer/canceled_subscription', default: 'external_templates/canceled_subscription_default' },
      household_disbanded_primary_email: { format: :html, placeholders: %w[support_email], fallback: 'external_templates/household_disbanded_primary_email' },
      household_disbanded_secondary_email: { format: :html, placeholders: %w[primary_member_name support_email], fallback: 'external_templates/household_disbanded_secondary_email' },
      reservation_reminder: { format: :text, placeholders: %w[reservation_title reservation_time resources reservations_url], fallback: 'external_templates/reservation_reminder' },
      volunteer_credit_awarded: { format: :text, placeholders: %w[credit_description credit_value year_total credit_plural], fallback: 'external_templates/volunteer_credit_awarded' },
      volunteer_credit_discount_earned: { format: :text, placeholders: [], fallback: 'external_templates/volunteer_credit_discount_earned' },
      volunteer_credit_discount_progress: { format: :text, placeholders: %w[credits_needed credit_plural], fallback: 'external_templates/volunteer_credit_discount_progress' },
      volunteer_credit_reversed: { format: :text, placeholders: %w[credit_description credit_value credit_plural reason reversed_by_name], fallback: 'external_templates/volunteer_credit_reversed' },
      volunteer_braintree_review: { format: :text, placeholders: %w[reversed_by_name reason], fallback: 'external_templates/volunteer_braintree_review' },
      volunteer_discount_applied_member: { format: :text, placeholders: %w[amount billing_cycles], fallback: 'external_templates/volunteer_discount_applied_member' },
      volunteer_discount_applied_admin: { format: :text, placeholders: %w[amount billing_cycles total_cycles discount_description], fallback: 'external_templates/volunteer_discount_applied_admin' },
      volunteer_discount_no_subscription: { format: :text, placeholders: [], fallback: 'external_templates/volunteer_discount_no_subscription' },
      volunteer_discount_error: { format: :text, placeholders: %w[error_message], fallback: 'external_templates/volunteer_discount_error' },
      household_disbanded_primary: { format: :text, placeholders: [], fallback: 'external_templates/household_disbanded_primary' },
      household_disbanded_secondary: { format: :text, placeholders: %w[primary_member_name], fallback: 'external_templates/household_disbanded_secondary' },
      household_disbanded_admin: { format: :text, placeholders: [], fallback: 'external_templates/household_disbanded_admin' },
      member_review_orientation: { format: :text, placeholders: [], fallback: 'external_templates/member_review_orientation' },
      member_review_no_purchase: { format: :text, placeholders: [], fallback: 'external_templates/member_review_no_purchase' },
      member_review_paypal: { format: :text, placeholders: [], fallback: 'external_templates/member_review_paypal' },
      member_review_missing_contract: { format: :text, placeholders: %w[contract_type document_url], fallback: 'external_templates/member_review_missing_contract' },
      member_review_expired_rental: { format: :text, placeholders: %w[rental_numbers renewal_url], fallback: 'external_templates/member_review_expired_rental' }
    }.freeze

    HTML_TAGS = %w[p div h1 h2 h3 h4 h5 h6 a strong b em i u ul ol li br blockquote table thead tbody tr th td].freeze
    HTML_ATTRIBUTES = %w[href title].freeze

    class << self
      def render(template_name, variables = {}, fallback: false, force_refresh: false, format: nil)
        name = normalize_name(template_name)
        definition = definition_for(name)
        selected_format = (format || definition[:format]).to_sym
        # The last valid export uses the Redis fast path. When no valid export
        # exists, each use retries Google until the document becomes valid.
        record = force_refresh ? refresh!(name) : cached_record(name)
        record ||= refresh!(name)
        render_content(record.fetch('content'), name, variables, selected_format)
      rescue => error
        discard_cached_content!(name) if name && record && (error.is_a?(InvalidTemplate) || error.is_a?(KeyError))
        report_error(error, template: template_name)
        return render_fallback(name, variables, selected_format) if fallback && name && definition
        nil
      end

      def refresh!(template_name)
        name = normalize_name(template_name)
        env_key = TEMPLATE_ENV_KEYS.fetch(name)
        file_id = ENV[env_key].presence
        raise MissingEnvironmentVariable, "#{env_key} is not set" unless file_id

        drive = ::Service::GoogleDrive.load_gdrive
        metadata = drive.get_file(file_id, fields: 'id,name,mime_type,modified_time,web_view_link,size')
        buffer = StringIO.new
        drive.export_file(file_id, 'text/html', download_dest: buffer)
        content = normalize_utf8(buffer.string)
        now = Time.current.iso8601

        if effectively_empty?(content)
          write_status(name, status_payload(name, 'empty', now, metadata: metadata, empty: true))
          raise InvalidTemplate, "#{env_key} refers to an effectively empty document"
        end

        validate_placeholders!(name, content)
        record = {
          'name' => name.to_s,
          'env_key' => env_key,
          'document_id' => file_id,
          'content' => content,
          'fetched_at' => now,
          'metadata' => metadata_hash(metadata)
        }
        REDIS.set(cache_key(name), JSON.generate(record))
        write_status(name, status_payload(name, 'ok', now, metadata: metadata, empty: false))
        record
      rescue MissingEnvironmentVariable
        write_status(name, status_payload(name, 'missing_env', Time.current.iso8601, error: "#{env_key} is not set")) if name
        raise
      rescue InvalidTemplate => error
        current = REDIS.get(status_key(name)) if name
        empty_status = begin
          current && JSON.parse(current)['status'] == 'empty'
        rescue JSON::ParserError
          false
        end
        unless empty_status
          write_status(name, status_payload(name, 'invalid', Time.current.iso8601, error: error.message)) if name
        end
        raise
      rescue JSON::ParserError => error
        write_status(name, status_payload(name, 'invalid', Time.current.iso8601, error: error.message)) if name
        raise InvalidTemplate, error.message
      rescue Google::Apis::Error => error
        permission = error.respond_to?(:status_code) && [401, 403].include?(error.status_code.to_i)
        wrapped = permission ? PermissionError.new(error.message) : TemplateError.new(error.message)
        write_status(name, status_payload(name, permission ? 'permission_error' : 'error', Time.current.iso8601, error: error.message)) if name
        raise wrapped
      rescue => error
        permission = error.is_a?(Signet::AuthorizationError)
        wrapped = permission ? PermissionError.new(error.message) : TemplateError.new(error.message)
        write_status(name, status_payload(name, permission ? 'permission_error' : 'error', Time.current.iso8601, error: error.message)) if name
        raise wrapped
      end

      def statuses
        TEMPLATE_ENV_KEYS.keys.map { |name| status(name) }
      end

      def status(template_name)
        name = normalize_name(template_name)
        env_key = TEMPLATE_ENV_KEYS.fetch(name)
        return public_status(status_payload(name, 'missing_env', nil, error: "#{env_key} is not set")) if ENV[env_key].blank?

        raw = REDIS.get(status_key(name))
        if raw
          parsed_status = JSON.parse(raw) rescue nil
          raw = nil unless parsed_status && parsed_status['document_id'] == ENV[env_key]
        end
        return public_status(JSON.parse(raw)) if raw

        cached = cached_record(name)
        state = cached ? 'ok' : 'uncached'
        public_status(status_payload(name, state, nil))
      end

      def restore_default!(template_name)
        name = normalize_name(template_name)
        write_document!(name, default_document_content(name))
        refresh!(name)
      end

      def populate!(template_name)
        name = normalize_name(template_name)
        current = status(name)
        raise InvalidTemplate, 'Populate is only available for an empty document' unless current[:status] == 'empty'
        restore_default!(name)
      end

      def placeholders_for(template_name)
        name = normalize_name(template_name)
        per_template = definition_for(name)[:placeholders].map(&:to_s)
        per_template + (COMMON_PLACEHOLDERS - per_template)
      end

      def common_variables(member)
        return {} unless member

        expiration = if member.respond_to?(:expirationTime) && member.expirationTime.present?
          Time.at(member.expirationTime.to_i / 1000).to_date.iso8601
        end
        slack_user = SlackUser.find_by(member_id: member.id) if defined?(SlackUser)
        {
          first_name: member.try(:firstname),
          last_name: member.try(:lastname),
          full_name: member.try(:fullname),
          email: member.try(:email),
          member_id: member.try(:id).to_s,
          join_date: (member.try(:startDate) || member.try(:created_at))&.to_date&.iso8601,
          expiration_date: expiration,
          slack_username: slack_user.try(:name),
          slack_id: slack_user.try(:slack_id),
          profile_url: member_profile_url(member),
          portal_url: Rails.configuration.x.try(:app_base_url),
          base_url: Rails.configuration.x.try(:app_base_url),
          open_house_schedule: ENV['OPEN_HOUSE_SCHEDULE']
        }
      end

      def clear_cache!(template_name)
        name = normalize_name(template_name)
        REDIS.del(cache_key(name), status_key(name))
      end

      private

      def definition_for(name)
        TEMPLATE_DEFINITIONS.fetch(name)
      end

      def normalize_name(name)
        name.to_sym
      end

      def cache_key(name)
        "#{CACHE_PREFIX}:#{name}:content"
      end

      def status_key(name)
        "#{CACHE_PREFIX}:#{name}:status"
      end

      def cached_record(name)
        raw = REDIS.get(cache_key(name))
        return unless raw

        record = JSON.parse(raw)
        env_key = TEMPLATE_ENV_KEYS.fetch(name)
        return unless ENV[env_key].present? && record['document_id'] == ENV[env_key]
        record
      rescue JSON::ParserError
        REDIS.del(cache_key(name))
        nil
      end

      def write_status(name, payload)
        REDIS.set(status_key(name), JSON.generate(payload))
      end

      def discard_cached_content!(name)
        REDIS.del(cache_key(name))
      end

      def status_payload(name, status, checked_at, metadata: nil, error: nil, empty: false)
        env_key = TEMPLATE_ENV_KEYS.fetch(name)
        cached = cached_record(name)
        {
          'name' => name.to_s,
          'env_key' => env_key,
          'document_id' => ENV[env_key].presence,
          'status' => status,
          'checked_at' => checked_at,
          'fetched_at' => cached&.dig('fetched_at'),
          'metadata' => metadata ? metadata_hash(metadata) : cached&.dig('metadata'),
          'empty' => empty,
          'error' => error
        }
      end

      def public_status(payload)
        name = payload.fetch('name').to_sym
        document_id = payload['document_id']
        {
          name: name.to_s,
          env_key: payload['env_key'],
          status: payload['status'],
          checked_at: payload['checked_at'],
          fetched_at: payload['fetched_at'],
          empty: payload['empty'],
          error: payload['error'],
          metadata: payload['metadata'],
          edit_url: document_id.present? ? "https://docs.google.com/document/d/#{ERB::Util.url_encode(document_id)}/edit" : nil,
          placeholders: placeholders_for(name),
          template_placeholders: definition_for(name)[:placeholders].map(&:to_s),
          common_placeholders: COMMON_PLACEHOLDERS
        }
      end

      def metadata_hash(metadata)
        {
          'id' => metadata.id,
          'name' => metadata.name,
          'mime_type' => metadata.mime_type,
          'modified_time' => metadata.modified_time.respond_to?(:iso8601) ? metadata.modified_time.iso8601 : metadata.modified_time,
          'web_view_link' => metadata.web_view_link,
          'size' => metadata.size
        }
      end

      def validate_placeholders!(name, content)
        used = content.scan(PLACEHOLDER_PATTERN).flatten.map(&:downcase).uniq
        allowed = placeholders_for(name)
        unknown = used - allowed
        return if unknown.empty?
        raise InvalidTemplate, "Unknown placeholder(s) for #{name}: #{unknown.join(', ')}"
      end

      def render_content(content, name, variables, format)
        content = extract_body(content)
        validate_placeholders!(name, content)
        content = html_to_text(content) if format == :text
        normalized_variables = variables.to_h.transform_keys(&:to_s)
        substituted = content.gsub(PLACEHOLDER_PATTERN) do
          key = Regexp.last_match(1).downcase
          sanitize_template_value(normalized_variables[key], format: format)
        end
        format == :html ? sanitize_html(substituted) : substituted.strip
      end

      def render_fallback(name, variables, format)
        template = definition_for(name)[:fallback]
        raise InvalidTemplate, "No fallback is configured for #{name}" if template.blank?
        locals = variables.to_h.symbolize_keys
        if format != :html
          locals = locals.transform_values { |value| sanitize_template_value(value, format: :text) }
        end
        ApplicationController.render(
          template: template,
          formats: [format == :html ? :html : :text],
          locals: locals,
          layout: false
        ).to_s.strip
      end

      def default_document_content(name)
        definition = definition_for(name)
        format = definition[:format] == :html ? 'html' : 'text'
        default_template = definition[:default] || definition[:fallback]
        path = Rails.root.join('app', 'views', "#{default_template}.#{format}.erb")
        raise InvalidTemplate, "Fallback file is missing for #{name}" unless File.file?(path)

        source = File.read(path, encoding: Encoding::UTF_8)
        source = source.gsub(/<%=\s*([a-z][a-z0-9_]*)\s*%>/i) { "{{#{Regexp.last_match(1)}}}" }
        source = source.gsub(/<%.*?%>/m, '')
        definition[:format] == :html ? html_to_text(source) : normalize_utf8(source).strip
      end

      def write_document!(name, text)
        env_key = TEMPLATE_ENV_KEYS.fetch(name)
        document_id = ENV[env_key].presence
        raise MissingEnvironmentVariable, "#{env_key} is not set" unless document_id

        token = google_access_token
        document = docs_request(:get, "/v1/documents/#{ERB::Util.url_encode(document_id)}", token: token)
        end_index = document.dig('body', 'content')&.last&.dig('endIndex').to_i
        requests = []
        if end_index > 2
          requests << { deleteContentRange: { range: { startIndex: 1, endIndex: end_index - 1 } } }
        end
        requests << { insertText: { location: { index: 1 }, text: text.to_s } }
        docs_request(:post, "/v1/documents/#{ERB::Util.url_encode(document_id)}:batchUpdate", token: token, body: { requests: requests })
      rescue PermissionError
        raise
      rescue => error
        raise TemplateError, error.message
      end

      def google_access_token
        credentials = ::Service::GoogleDrive.load_gdrive.authorization
        token = credentials.fetch_access_token!
        token['access_token'] || token[:access_token]
      end

      def docs_request(method, path, token:, body: nil)
        uri = URI("https://docs.googleapis.com#{path}")
        request = method == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
        request['Authorization'] = "Bearer #{token}"
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate(body) if body
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15) { |http| http.request(request) }
        parsed = response.body.present? ? JSON.parse(response.body) : {}
        return parsed if response.is_a?(Net::HTTPSuccess)

        message = parsed.dig('error', 'message') || "Google Docs request failed with #{response.code}"
        raise PermissionError, message if %w[401 403].include?(response.code)
        raise TemplateError, message
      end

      def effectively_empty?(html)
        html_to_text(extract_body(html)).gsub(/[\p{C}\p{Z}]/, '').empty?
      end

      def extract_body(html)
        match = normalize_utf8(html).match(/<body[^>]*>(.*?)<\/body>/mi)
        match ? match[1].strip : html
      end

      def sanitize_template_value(value, format: :html)
        normalized = normalize_utf8(value.to_s)
        if format.to_sym == :html
          ERB::Util.html_escape(normalized)
        else
          normalized.gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/, '')
                    .gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end

      def sanitize_html(html)
        ActionController::Base.helpers.sanitize(normalize_utf8(html), tags: HTML_TAGS, attributes: HTML_ATTRIBUTES)
      end

      def html_to_text(html)
        value = normalize_utf8(html)
        value = value.gsub(/<\s*br\s*\/?>/i, "\n")
                     .gsub(/<\/(p|div|h[1-6]|li|tr)>/i, "\n")
        CGI.unescapeHTML(ActionController::Base.helpers.strip_tags(value))
          .gsub("\u00A0", ' ')
          .gsub(/[ \t]+\n/, "\n")
          .gsub(/\n{3,}/, "\n\n")
          .strip
      end

      def normalize_utf8(value)
        normalized = value.to_s.dup
        normalized.force_encoding(Encoding::UTF_8) if normalized.encoding == Encoding::ASCII_8BIT
        normalized.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '').unicode_normalize
      rescue Encoding::CompatibilityError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '').unicode_normalize
      end

      def member_profile_url(member)
        base = Rails.configuration.x.try(:app_base_url).to_s.sub(%r{/$}, '')
        base.present? ? "#{base}/members/#{member.id}" : nil
      end

      def report_error(error, template:)
        context = { template: template.to_s, error: error.message }
        if error.is_a?(MissingEnvironmentVariable)
          Rails.logger.info("[EmailTemplate] Using compiled fallback: #{error.message}")
        elsif defined?(Honeybadger)
          Honeybadger.notify(error, context: context)
        else
          Rails.logger.error("[EmailTemplate] #{error.class}: #{error.message} | #{context.inspect}")
        end
      end
    end
  end
end
