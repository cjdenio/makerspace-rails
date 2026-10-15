require 'rails_helper'
require 'rake'

RSpec.describe 'backup' do
  let(:task) { Rake::Task['backup'] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('backup')
    task.reenable
    allow(Dir).to receive(:mkdir)
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with('dump').and_return(true)
    allow(File).to receive(:write)
    allow(File).to receive(:delete)
    allow_any_instance_of(Object).to receive(:system).and_return(true)
    allow(Service::GoogleDrive).to receive(:upload_backup)
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::SlackConnector).to receive(:logs_channel).and_return('logs')
  end

  after { task.reenable }

  def with_mlab_uri(value)
    original = ENV['MLAB_URI']
    ENV['MLAB_URI'] = value
    yield
  ensure
    ENV['MLAB_URI'] = original
  end

  it 'strips wrapping single quotes left over from how the env var was set' do
    with_mlab_uri("'mongodb+srv://user:pass@test-host/db'") { task.invoke }

    expect(File).to have_received(:write).with(
      anything, "uri: \"mongodb+srv://user:pass@test-host/db\"\n"
    )
  end

  it 'strips wrapping double quotes' do
    with_mlab_uri('"mongodb+srv://user:pass@test-host/db"') { task.invoke }

    expect(File).to have_received(:write).with(
      anything, "uri: \"mongodb+srv://user:pass@test-host/db\"\n"
    )
  end

  it 'leaves an already-clean URI unchanged' do
    with_mlab_uri('mongodb+srv://user:pass@test-host/db') { task.invoke }

    expect(File).to have_received(:write).with(
      anything, "uri: \"mongodb+srv://user:pass@test-host/db\"\n"
    )
  end
end
