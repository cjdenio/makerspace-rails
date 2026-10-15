require 'cgi'

module SanitizesUserInput
  extend ActiveSupport::Concern

  SANITIZER = Class.new do
    include ActionView::Helpers::SanitizeHelper
  end.new

  # Fields that must never be run through sanitization. This covers two
  # categories of risk:
  #
  #   1. Encrypted/hashed credentials and tokens (encrypted_password,
  #      otp_secret_encrypted, *_token) - these can contain raw
  #      non-UTF-8 binary data (e.g. AES-256-CBC ciphertext), and
  #      normalize_for_sanitization's UTF-8 coercion step silently drops
  #      any byte sequence that isn't valid UTF-8. Running that over a
  #      bcrypt hash or encrypted secret on every save risks silently
  #      corrupting authentication data.
  #   2. External-system identifiers (*_id, firebase_uid) - these are
  #      opaque references (Braintree customer/subscription IDs, Slack
  #      IDs, Mailtrap IDs, Firebase UIDs), not user-authored text, and
  #      must round-trip byte-for-byte to keep working as lookup keys.
  #
  # Everything else - names, addresses, notes, descriptions, etc. - is
  # genuine user-facing text and is safe (and intended) to sanitize.
  SENSITIVE_FIELD_NAMES = %w[
    encrypted_password
    otp_secret
    otp_secret_encrypted
    firebase_uid
  ].freeze

  SENSITIVE_FIELD_SUFFIXES = %w[_id _token].freeze

  def self.sensitive_field?(field_name)
    name = field_name.to_s
    SENSITIVE_FIELD_NAMES.include?(name) ||
      SENSITIVE_FIELD_SUFFIXES.any? { |suffix| name.end_with?(suffix) }
  end

  included do
    before_validation :sanitize_string_attributes
  end

  class_methods do
    def scrub_user_input(value)
      return value unless value.is_a?(String)

      sanitize_plain_text(normalize_for_sanitization(value))
    end

    def sanitize_plain_text(value)
      decoded_value = CGI.unescapeHTML(value)
      CGI.unescapeHTML(SANITIZER.sanitize(decoded_value, tags: [], attributes: []))
    end

    def normalize_for_sanitization(value)
      normalized_value = value.dup
      normalized_value.force_encoding(Encoding::UTF_8) if normalized_value.encoding == Encoding::ASCII_8BIT
      normalized_value = normalized_value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
      normalized_value.unicode_normalize
    rescue Encoding::CompatibilityError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '').unicode_normalize
    end
  end

  private

  def sanitize_string_attributes
    self.class.fields.each_key do |field_name|
      next if SanitizesUserInput.sensitive_field?(field_name)

      value = read_attribute(field_name)
      write_attribute(field_name, self.class.scrub_user_input(value)) if value.is_a?(String)
    end
  end
end
