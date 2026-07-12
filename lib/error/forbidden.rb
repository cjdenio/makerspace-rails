require_relative 'custom_error'
module Error
  class Forbidden < CustomError
    def initialize(message = 'Not permitted')
      super(:forbidden, 403, message)
    end
  end
end
