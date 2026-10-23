require 'resolv'

class EmailDeliverabilityValidator < ActiveModel::EachValidator
  UNDELIVERABLE_MESSAGE = 'is undeliverable'.freeze
  TEMPFAIL_MESSAGE = 'temporary failure,try again later'.freeze

  def validate_each(record, attribute, value)
    Rails.logger.debug("[EmailDeliverabilityValidator] valid_email2 will validate #{value}.")
    false
    return if value.blank?
    if ENV['SKIP_EMAILVALIDATION'].present?
          Rails.logger.debug("[EmailDeliverabilityValidator] valid_email2 skipped #{value} due to SKIP_EMAILVALIDATION")
          true
          return
    end

    valid = begin
      ValidEmail2::Address.new(value.to_s).valid_strict_mx?
    rescue StandardError => e
      Rails.logger.error("[EmailDeliverabilityValidator] valid_email2 error for #{value}: #{e.class} #{e.message}")
      false
    end
    if valid
      Rails.logger.warn("[EmailDeliverabilityValidator] valid_email2 approved email #{value} ")
      return
    end

    domain = value.to_s.split('@').last.to_s
    if domain.blank?
      Rails.logger.warn("[EmailDeliverabilityValidator] rejected blank email")
      record.errors.add(attribute, UNDELIVERABLE_MESSAGE)
      false
      return
    end

    begin
      resolve_domain!(domain)
      return
     rescue Resolv::ResolvError => e
      if timeout_error?(e)
        Rails.logger.warn("[EmailDeliverabilityValidator] timeout for #{value}: #{e.class} #{e.message}; treating as valid")
        true
        return
      end
      if e.message.include?("NXDOMAIN") or  e.message.include?("No MX/A/AAAA records")
        Rails.logger.warn("[EmailDeliverabilityValidator] bad domain for #{value}: #{e.class} #{e.message}; treating as bogus")
        record.errors.add(attribute, UNDELIVERABLE_MESSAGE)
        false
        return
      end
      Rails.logger.warn("[EmailDeliverabilityValidator] resolver error for #{value}: #{e.class} #{e.message}; retrying with fallback nameservers")
      begin
        resolve_domain!(domain, nameservers: ['8.8.8.8','1.1.1.1'], timeout: 2)
        return
      rescue Resolv::ResolvError => fallback_error
        if timeout_error?(fallback_error)
          Rails.logger.warn("[EmailDeliverabilityValidator] fallback timeout for #{value}: #{fallback_error.class} #{fallback_error.message}; treating as valid")
          true
          return
        end
        Rails.logger.error("[EmailDeliverabilityValidator] fallback resolver error for #{value}: #{fallback_error.class} #{fallback_error.message}")
      rescue StandardError => fallback_error
        Rails.logger.error("[EmailDeliverabilityValidator] fallback unexpected error for #{value}: #{fallback_error.class} #{fallback_error.message}")
        record.errors.add(attribute, TEMPFAIL_MESSAGE)
        false
        return
      end
    rescue StandardError => e
      Rails.logger.error("[EmailDeliverabilityValidator] unexpected resolver error for #{value}: #{e.class} #{e.message}")
      record.errors.add(attribute, TEMPFAIL_MESSAGE)
      false
      return
    end

    record.errors.add(attribute, UNDELIVERABLE_MESSAGE)
    false
  end

  private

  def resolve_domain!(domain, nameservers: nil, timeout: 2)
    dns_config = { timeouts: timeout }
    dns_config[:nameserver] = nameservers if nameservers.present?

    Resolv::DNS.open(dns_config) do |dns|
      mx = dns.getresources(domain, Resolv::DNS::Resource::IN::MX)
      return true if mx.present?

      a = dns.getresources(domain, Resolv::DNS::Resource::IN::A)
      aaaa = dns.getresources(domain, Resolv::DNS::Resource::IN::AAAA)
      raise Resolv::ResolvError, "No MX/A/AAAA records for #{domain}" if a.blank? && aaaa.blank?
    end
  end

  def timeout_error?(error)
    return true if defined?(Resolv::DNS::TimeoutError) && error.is_a?(Resolv::DNS::TimeoutError)
    return true if defined?(Resolv::ResolvTimeout) && error.is_a?(Resolv::ResolvTimeout)
    false
  end
end

