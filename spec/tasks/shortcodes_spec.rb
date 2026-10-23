require "rails_helper"
require "rake"

RSpec.describe "shortcode index setup" do
  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("shortcodes:ensure_indexes")
    Service::DatabaseSafety.ensure_safe_mlab_uri!(operation: "Shortcode index test collection drop")
    Shortcode.collection.drop
    ShortUrl.instance_variable_set(:@indexes_verified, false)
    %w[shortcodes:ensure_indexes db:mongoid:create_indexes].each { |name| Rake::Task[name].reenable }
  end

  after do
    Shortcode.collection.drop
    Shortcode.create_indexes
    ShortUrl.instance_variable_set(:@indexes_verified, false)
  end

  def expect_full_indexes
    %w[code target_url].each do |field|
      expect(Shortcode.current_indexes.any? { |index| Shortcode.full_unique_index?(index, field) }).to eq(true)
    end
  end

  [nil, :partial, :sparse, :nonunique].each do |kind|
    ["shortcodes:ensure_indexes", "db:mongoid:create_indexes"].each do |command|
      it "upgrades #{kind || 'absent'} indexes through #{command}" do
        if kind
          %w[code target_url].each do |field|
            options = { unique: kind != :nonunique }
            options[:sparse] = true if kind == :sparse
            options[:partial_filter_expression] = { field => { '$type' => 'string' } } if kind == :partial
            Shortcode.collection.indexes.create_one({ field => 1 }, options)
          end
          Shortcode.collection.insert_one(code: "23456789AB", target_url: "/rentals/spots/0123456789abcdef01234567")
        end
        if command == "db:mongoid:create_indexes"
          # Run the actual rake task, scoped to this model to avoid unrelated
          # existing index conflicts in other collections in the test database.
          allow(Mongoid).to receive(:models).and_return([Shortcode])
          expect(Shortcode).to receive(:create_indexes).at_least(:twice).and_wrap_original do |original, *args|
            expect(Shortcode.current_indexes).not_to include(include("sparse" => true))
            expect(Shortcode.current_indexes).not_to include(have_key("partialFilterExpression"))
            original.call(*args)
          end
        end
        expect { Rake::Task[command].invoke }.not_to raise_error
        expect_full_indexes
        expect(Shortcode.count).to eq(kind ? 1 : 0)
        Rake::Task["shortcodes:ensure_indexes"].reenable
        expect { Rake::Task["shortcodes:ensure_indexes"].invoke }.not_to raise_error
      end
    end
  end

  it "creates both indexes on first allocation into a missing collection" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("APP_DOMAIN").and_return("members.example.org")
    allow(REDIS).to receive(:get).and_return(nil)
    allow(REDIS).to receive(:set).and_return("OK")
    expect(Shortcode).to receive(:create!).and_wrap_original do |original, *args|
      expect_full_indexes
      original.call(*args)
    end
    result = ShortUrl.allocate("/rentals/spots/0123456789abcdef01234567")
    expect(result[:code]).to match(ShortUrl::CODE)
    expect_full_indexes
  end

  it "retains old indexes and mappings when duplicates prevent an upgrade" do
    Shortcode.collection.indexes.create_one({ code: 1 }, unique: true, sparse: true)
    Shortcode.collection.insert_many([{ code: "23456789AB", target_url: "same" }, { code: "23456789AC", target_url: "same" }])
    expect { Rake::Task["shortcodes:ensure_indexes"].invoke }.to raise_error(/duplicate values/)
    expect(Shortcode.current_indexes).to include(include("name" => "code_1", "sparse" => true))
    expect(Shortcode.count).to eq(2)
  end
end
