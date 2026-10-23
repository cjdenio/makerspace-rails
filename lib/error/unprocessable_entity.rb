require_relative 'custom_error'
module Error
  class UnprocessableEntity < CustomError
    def initialize(message = nil)
      super(:unprocessable_content, 422, message || 'Unable to process entity')
    end
  end
end