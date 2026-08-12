require "rails_helper"

RSpec.describe "reservations:backfill_resource_manager_shops" do
  before do
    Rails.application.load_tasks
    Rake::Task["reservations:backfill_resource_manager_shops"].reenable
  end

  it "backfills legacy resource managers without overwriting explicit assignments" do
    first_shop = create(:shop)
    second_shop = create(:shop)
    legacy_manager = create(:member, :resource_manager)
    unassigned_manager = create(
      :member,
      :resource_manager,
      resource_manager_shop_ids: []
    )
    Member.collection.find(_id: legacy_manager.id).update_one(
      "$unset" => { resource_manager_shop_ids: true }
    )

    Rake::Task["reservations:backfill_resource_manager_shops"].invoke

    expect(legacy_manager.reload.resource_manager_shop_ids.map(&:to_s))
      .to contain_exactly(first_shop.id.to_s, second_shop.id.to_s)
    expect(unassigned_manager.reload.resource_manager_shop_ids).to eq([])
  end
end
