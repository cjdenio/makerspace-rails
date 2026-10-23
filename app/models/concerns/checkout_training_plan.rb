module CheckoutTrainingPlan
  extend ActiveSupport::Concern

  included do
    field :checkout_training_plan_url, type: String
    before_validation do
      self.checkout_training_plan_url = checkout_training_plan_url.to_s.strip.presence
    end
    validates :checkout_training_plan_url, length: { maximum: 2048 }, allow_nil: true
    validate do
      next if checkout_training_plan_url.blank?
      begin
        uri = URI.parse(checkout_training_plan_url)
        valid = uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil?
      rescue URI::InvalidURIError
        valid = false
      end
      errors.add(:checkout_training_plan_url, 'must be an absolute HTTP or HTTPS URL') unless valid
    end
  end
end
