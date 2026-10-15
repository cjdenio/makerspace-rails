namespace :google_resources do
  desc "Ensure every shop/tool has a Google Workspace resource and Calendar label"
  task reconcile: :environment do
    Shop.all.each { |shop| GoogleResourceSyncJob.perform_later("Shop", shop.id.to_s) }
    Tool.all.each { |tool| GoogleResourceSyncJob.perform_later("Tool", tool.id.to_s) }
  end
end
