require "spec_helper"
require "pathname"
require "yaml"

RSpec.describe "Heroku process configuration" do
  let(:repository_root) { Pathname.new(__dir__).join("../..").expand_path }

  let(:maintenance_command) do
    "bundle exec rake reservations:backfill_resource_manager_shops earned_memberships:backfill_status data:ensure_unique_indexes"
  end

  it "runs database maintenance in the container release phase" do
    config = YAML.safe_load(repository_root.join("heroku.yml").read)

    expect(config.dig("release", "image")).to eq("web")
    expect(config.dig("release", "command")).to eq([maintenance_command])
    expect(config.dig("run", "web")).to eq("bundle exec puma -C config/puma.rb")
  end

  it "does not block container web startup on database maintenance" do
    dockerfile = repository_root.join("Dockerfile").read

    expect(dockerfile).to include('CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]')
    expect(dockerfile.lines.grep(/^CMD /).join).not_to include(maintenance_command)
  end

  it "keeps buildpack process types consistent with container deployments" do
    process_types = repository_root.join("Procfile").read.lines.to_h do |line|
      name, command = line.chomp.split(": ", 2)
      [name, command]
    end

    expect(process_types).to include(
      "release" => maintenance_command,
      "web" => "bundle exec puma -C config/puma.rb"
    )
  end
end
