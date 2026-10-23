require_relative 'custom_error'
module Error
  class AlreadyClaimed < CustomError
    def initialize
      super(:unprocessable_content, 422, 'You have already claimed this task')
    end
  end
end
