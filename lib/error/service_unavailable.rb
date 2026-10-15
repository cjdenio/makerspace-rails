require_relative 'custom_error'

module Error
  class ServiceUnavailable < CustomError
    def initialize(message = nil)
      super(:service_unavailable, 503, message || 'Service unavailable')
    end
  end
end
