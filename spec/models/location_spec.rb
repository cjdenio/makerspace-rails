require 'rails_helper'

RSpec.describe Location, type: :model do
  describe "Mongoid validations" do
    it { is_expected.to be_mongoid_document }
    it { is_expected.to be_stored_in(collection: 'locations') }

    it { is_expected.to have_field(:name).of_type(String) }
    it { is_expected.to have_field(:kind).of_type(String) }
    it { is_expected.to have_field(:parent_id).of_type(BSON::ObjectId) }
    it { is_expected.to have_field(:svg_element_id).of_type(String) }
    it { is_expected.to have_field(:x_pct).of_type(Float) }
    it { is_expected.to have_field(:y_pct).of_type(Float) }
    it { is_expected.to have_field(:shape_points).of_type(Array) }
    it { is_expected.to have_field(:floor_name).of_type(String) }
    it { is_expected.to have_field(:icon).of_type(String) }
  end

  describe "ActiveModel validations" do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to belong_to(:shop) }
  end

  it "has a valid factory" do
    expect(build(:location)).to be_valid
  end

  context "public methods" do
    it "finds its parent" do
      shop = create(:shop)
      parent = create(:location, shop: shop)
      child = create(:location, shop: shop, parent_id: parent.id)

      expect(child.parent).to eq(parent)
    end

    it "returns nil for parent when there is none" do
      expect(build(:location).parent).to be_nil
    end

    it "finds its children" do
      shop = create(:shop)
      parent = create(:location, shop: shop)
      child = create(:location, shop: shop, parent_id: parent.id)
      create(:location, shop: shop) # unrelated sibling location

      expect(parent.children.to_a).to eq([child])
    end

    it "is invalid when its parent belongs to a different shop" do
      other_shop_parent = create(:location, shop: create(:shop))
      child = build(:location, shop: create(:shop), parent_id: other_shop_parent.id)

      expect(child).not_to be_valid
      expect(child.errors[:parent_id]).to include("must belong to the same shop")
    end

    it "is valid when its parent belongs to the same shop" do
      shop = create(:shop)
      parent = create(:location, shop: shop)
      child = build(:location, shop: shop, parent_id: parent.id)

      expect(child).to be_valid
    end

    it "is invalid when shape_points has fewer than 3 points" do
      location = build(:location, shape_points: [{ x: 10, y: 10 }, { x: 20, y: 20 }])

      expect(location).not_to be_valid
      expect(location.errors[:shape_points]).to include("must have at least 3 points to form a shape")
    end

    it "is valid when shape_points has 3 or more points" do
      location = build(:location, shape_points: [{ x: 10, y: 10 }, { x: 50, y: 10 }, { x: 30, y: 40 }])

      expect(location).to be_valid
    end

    it "is invalid when a shape_points value is outside 0-100" do
      location = build(:location, shape_points: [{ x: 10, y: 10 }, { x: 133, y: 10 }, { x: 30, y: 40 }])

      expect(location).not_to be_valid
      expect(location.errors[:shape_points]).to include("must have x/y values between 0 and 100")
    end

    it "is invalid when x_pct or y_pct is outside 0-100" do
      location = build(:location, x_pct: 133, y_pct: 50)

      expect(location).not_to be_valid
      expect(location.errors[:x_pct]).to be_present
    end
  end

  describe "floor and icon" do
    it "has a public-map glyph for every marker icon" do
      expect(MarkerGlyphs::PATHS.keys).to match_array(Location::ICONS)
      expect(MarkerGlyphs.path("not-an-icon")).to eq(MarkerGlyphs::PATHS["pin"])
    end

    let(:shop) { create(:shop, floor_name: "1") }

    it "falls back to the shop's floor when none is set" do
      expect(create(:location, shop: shop).effective_floor_name).to eq("1")
      expect(create(:location, shop: shop, floor_name: "2").effective_floor_name).to eq("2")
    end

    it "accepts only known floors and icons, treating blanks as unset" do
      expect(build(:location, shop: shop, floor_name: "9")).not_to be_valid
      expect(build(:location, shop: shop, icon: "rocket")).not_to be_valid
      location = build(:location, shop: shop, floor_name: "", icon: "")
      expect(location).to be_valid
      expect(location.floor_name).to be_nil
      expect(location.icon).to be_nil
      expect(build(:location, shop: shop, floor_name: "B", icon: "saw")).to be_valid
    end

    it "makes a nested location inherit its parent's floor" do
      parent = create(:location, shop: shop, floor_name: "2")
      child = create(:location, shop: shop, parent_id: parent.id)
      expect(child.floor_name).to eq("2")
    end

    it "rejects a child on a different floor than its parent" do
      parent = create(:location, shop: shop, floor_name: "2")
      child = build(:location, shop: shop, parent_id: parent.id, floor_name: "B")
      expect(child).not_to be_valid
      expect(child.errors[:floor_name]).to be_present
    end

    it "moves everything nested in a location when its floor changes" do
      parent = create(:location, shop: shop, floor_name: "1")
      child = create(:location, shop: shop, parent_id: parent.id)
      grandchild = create(:location, shop: shop, parent_id: child.id)
      parent.update!(floor_name: "2")
      expect([child.reload.floor_name, grandchild.reload.floor_name]).to eq(%w[2 2])
    end
  end
end
