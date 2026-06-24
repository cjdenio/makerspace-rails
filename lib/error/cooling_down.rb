require_relative 'custom_error'
module Error
  class CoolingDown < CustomError
    def initialize
      super(:unprocessable_entity, 422, 'This task is not yet available to claim again')
    end
  end
end
