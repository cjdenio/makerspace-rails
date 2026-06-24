require_relative 'custom_error'
module Error
  class NotAllowed < CustomError
    def initialize(message = 'Not allowed in this environment')
      super(:unprocessable_entity, 422, message)
    end
  end
end
