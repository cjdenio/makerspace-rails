desc "This task is called by the Heroku scheduler add-on and backs up the Mongo DB to local dump."
task :backup => :environment do
  dump_dir = "dump"
  config_file = "/tmp/mongodump_config.yml"
  backup_error = nil
  begin
    Dir.mkdir(dump_dir) unless File.exists?(dump_dir)
    file_name = "makerauthBackup_#{Time.now.strftime('%m-%d-%Y')}.archive"
    File.write(config_file, "uri: \"#{ENV['MLAB_URI']}\"\n")
    sh("/usr/bin/mongodump --config=#{config_file} --archive=#{dump_dir}/#{file_name}")
    Service::GoogleDrive.upload_backup(file_name)
    slack_message = "Daily backup complete."
  rescue => e
    backup_error = e
    error = "#{e.message}\n#{e.backtrace.inspect}"
    slack_message = "Error backing up database: #{error}"
  ensure
    File.delete(config_file) if File.exist?(config_file)
  end
  ::Service::SlackConnector.send_slack_message(slack_message, ::Service::SlackConnector.logs_channel)
  raise backup_error if backup_error
end
