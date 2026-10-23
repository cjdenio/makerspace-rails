FactoryBot.define do
  factory :fix_ticket do
    reporter_id { create(:member, :current).id }
    title { 'Drill' }
    description { 'Switch failed' }
    category { 'broken' }
    submission_key { SecureRandom.uuid }
  end
end
