# TotpService — wraps rotp for TOTP generation and verification.
#
# The OTP secret is stored encrypted in MongoDB using AES-256-CBC
# keyed by the OTP_SECRET_KEY environment variable (32-byte base64 string).
# Generate with: openssl rand -base64 32
#
# Usage:
#   secret = TotpService.generate_secret
#   encrypted = TotpService.encrypt(secret)
#   member.update!(otp_secret_encrypted: encrypted)
#
#   TotpService.valid?(code, member.otp_secret_encrypted)  # => true/false
#   TotpService.qr_svg(member)                             # => SVG string
#
require 'rotp'
require 'rqrcode'
require 'openssl'
require 'base64'

class TotpService
  ALGORITHM = 'AES-256-CBC'.freeze
  ISSUER    = 'Manchester Makerspace'.freeze

  # Generate a new random base32 secret
  def self.generate_secret
    ROTP::Base32.random
  end

  # Encrypt a plain secret for storage in MongoDB
  def self.encrypt(plain_secret)
    cipher = OpenSSL::Cipher.new(ALGORITHM)
    cipher.encrypt
    cipher.key = encryption_key
    iv = cipher.random_iv
    encrypted = cipher.update(plain_secret) + cipher.final
    # Prefix iv to ciphertext, base64 encode the whole thing
    Base64.strict_encode64(iv + encrypted)
  end

  # Decrypt stored secret back to plain base32 string
  def self.decrypt(encrypted_secret)
    raw        = Base64.decode64(encrypted_secret)
    cipher     = OpenSSL::Cipher.new(ALGORITHM)
    cipher.decrypt
    cipher.key = encryption_key
    iv         = raw[0, 16]
    ciphertext = raw[16..]
    cipher.iv  = iv
    cipher.update(ciphertext) + cipher.final
  end

  # Validate a 6-digit code against the member's encrypted secret.
  # Allows 1 time-step drift (30s each side) to account for clock skew.
  def self.valid?(code, encrypted_secret)
    return false if code.blank? || encrypted_secret.blank?
    plain  = decrypt(encrypted_secret)
    totp   = ROTP::TOTP.new(plain, issuer: ISSUER)
    result = totp.verify(code.to_s.strip, drift_behind: 30, drift_ahead: 30)
    result.present?
  rescue StandardError => e
    Rails.logger.error("[TotpService] Verification error: #{e.class}: #{e.message}")
    false
  end

  # Quick sanity check — run from Rails console to verify the service works:
  #   TotpService.self_test
  def self.self_test
    secret    = generate_secret
    encrypted = encrypt(secret)
    decrypted = decrypt(encrypted)
    raise "Decrypt mismatch!" unless decrypted == secret
    totp = ROTP::TOTP.new(secret, issuer: ISSUER)
    code = totp.now
    ok   = valid?(code, encrypted)
    raise "TOTP verify failed!" unless ok
    puts "TotpService.self_test PASSED — key OK, encrypt/decrypt OK, TOTP verify OK"
    true
  rescue => e
    puts "TotpService.self_test FAILED: #{e.message}"
    false
  end

  # Generate a provisioning URI for QR code display
  def self.provisioning_uri(member, plain_secret)
    totp = ROTP::TOTP.new(plain_secret, issuer: ISSUER)
    totp.provisioning_uri(member.email)
  end

  # Return an inline SVG string for the QR code
  def self.qr_svg(member, plain_secret)
    uri    = provisioning_uri(member, plain_secret)
    qrcode = RQRCode::QRCode.new(uri)
    qrcode.as_svg(
      color:            '000',
      shape_rendering:  'crispEdges',
      module_size:       4,
      standalone:        true,
      use_path:          true
    )
  end

  private

  def self.encryption_key
    raw = ENV.fetch('OTP_SECRET_KEY') do
      raise 'OTP_SECRET_KEY environment variable is not set'
    end
    # Use lenient decode + strip to handle any whitespace/line endings from copy-paste
    Base64.decode64(raw.to_s.strip)[0, 32]
  end
end
