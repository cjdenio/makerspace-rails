require "rails_helper"

RSpec.describe Service::Analytics do
  describe Service::Analytics::Members do
    let(:january_end) { Date.new(2024, 1, 31).to_time }

    before do
      Member.collection.insert_many([
        { status: "activeMember", firstname: "Exact", lastname: "Start", startDate: january_end, expirationTime: january_end.to_i * 1000 },
        { status: "pending", firstname: "Exact", lastname: "Expiry", startDate: january_end - 1.month, expirationTime: january_end.to_i * 1000 },
        { status: "activeMember", firstname: "Too", lastname: "Early", startDate: january_end - 1.month, expirationTime: (january_end.to_i * 1000) - 1 },
        { status: "activeMember", firstname: "Too", lastname: "Late", startDate: january_end + 1.second, expirationTime: january_end.to_i * 1000 },
        { status: "inactive", firstname: "Wrong", lastname: "Status", startDate: january_end - 1.month, expirationTime: january_end.to_i * 1000 },
        { status: "inactive", firstname: "Midmonth", lastname: "Start", startDate: Time.utc(2024, 1, 15), expirationTime: Time.utc(2024, 2, 15).to_i * 1000 },
        { status: "inactive", firstname: "Midmonth", lastname: "Expiry", startDate: Time.utc(2023, 12, 15), expirationTime: Time.utc(2024, 1, 15).to_i * 1000 }
      ])
    end

    it "computes all summary counters with one faceted aggregation" do
      travel_to january_end do
        Member.collection.insert_many([
          { status: "activeMember", firstname: "New", lastname: "Subscriber", startDate: 1.day.ago, expirationTime: 1.month.from_now.to_i * 1000, subscription: true },
          { status: "inactive", firstname: "Recently", lastname: "Lost", startDate: 1.year.ago, expirationTime: 1.day.ago.to_i * 1000 },
          { status: "activeMember", firstname: "Landlord", lastname: "Ignored", startDate: 1.day.ago, expirationTime: 1.month.from_now.to_i * 1000 }
        ])

        expect(described_class.summary_counts).to eq(
          total_members: described_class.query_total_members.count,
          new_members: described_class.query_new_members.count,
          lost_members: described_class.query_lost_members.count,
          subscribed_members: described_class.query_braintree_members.count
        )
      end
    end

    it "includes members starting or expiring exactly at month end and zero-fills empty months" do
      expect(described_class.active_members_by_month(
        start_date: Date.new(2024, 1, 1), end_date: Date.new(2024, 2, 29),
        statuses: Member::ACTIVE_MEMBERSHIP_STATUSES
      )).to eq([
        { date: "2024-01", count: 2 },
        { date: "2024-02", count: 0 }
      ])
    end

    it "preserves the legacy start-of-month boundary, shape, and historical statuses" do
      expect(described_class.get_membership_per_month(
        Mongoid::Criteria.new(Member), Date.new(2024, 1, 1)
      ).first).to eq([Date.new(2024, 1, 1), 4])
    end

    it "never generates a wholly future month and clamps the current month's :end boundary to now" do
      travel_to Time.utc(2024, 6, 15, 12, 0, 0) do
        Member.collection.insert_many([
          { status: "activeMember", firstname: "Still", lastname: "Active", startDate: Time.utc(2024, 1, 1), expirationTime: Time.utc(2024, 6, 20).to_i * 1000 }
        ])

        result = described_class.active_members_by_month(
          start_date: Date.new(2024, 6, 1), end_date: Date.new(2024, 12, 31),
          statuses: Member::ACTIVE_MEMBERSHIP_STATUSES
        )

        expect(result.map { |r| r[:date] }).to eq(["2024-06"])
        expect(result).to eq([{ date: "2024-06", count: 1 }])
      end
    end
  end

  describe Service::Analytics::Members do
    describe ".query_lost_members" do
      it "only includes members whose expiration already passed within the timeframe" do
        travel_to Time.utc(2024, 6, 15, 12, 0, 0) do
          Member.collection.insert_many([
            { status: "activeMember", firstname: "Recently", lastname: "Expired", expirationTime: 10.days.ago.to_i * 1000 },
            { status: "activeMember", firstname: "Not", lastname: "YetExpired", expirationTime: 10.days.from_now.to_i * 1000 },
            { status: "inactive", firstname: "LongAgo", lastname: "Expired", expirationTime: 40.days.ago.to_i * 1000 }
          ])

          expect(described_class.query_lost_members.pluck(:firstname)).to eq(["Recently"])
        end
      end
    end

    describe ".lost_members_by_month" do
      it "buckets by the month expiration actually fell in, excluding not-yet-passed expirations" do
        travel_to Time.utc(2024, 6, 15, 12, 0, 0) do
          Member.collection.insert_many([
            { status: "inactive", firstname: "Past", lastname: "Month", expirationTime: Time.utc(2024, 5, 10).to_i * 1000 },
            { status: "activeMember", firstname: "Already", lastname: "ExpiredThisMonth", expirationTime: Time.utc(2024, 6, 10).to_i * 1000 },
            { status: "activeMember", firstname: "NotYet", lastname: "ExpiredThisMonth", expirationTime: Time.utc(2024, 6, 20).to_i * 1000 }
          ])

          result = described_class.lost_members_by_month(start_date: Date.new(2024, 1, 1))

          expect(result).to eq([
            { month: "2024-05", count: 1 },
            { month: "2024-06", count: 1 }
          ])
        end
      end
    end
  end

  describe Service::Analytics::Invoices do
    before do
      Invoice.collection.insert_many([
        { plan_id: "membership-one-month-recurring", amount: 25.0, settled_at: Time.current },
        { plan_id: "membership-one-month-recurring", discount_id: "monthly_membership_sso", amount: 10.0, settled_at: Time.current },
        { plan_id: "membership-one-month-recurring", discount_id: "other-discount", amount: nil, settled_at: Time.current },
        { plan_id: "membership-one-month-recurring", amount: 99.0, settled_at: nil },
        { plan_id: "rental-quarterly-recurring-locker-subscription", amount: nil, settled_at: Time.current }
      ])
    end

    it "aggregates settled regular and discounted memberships, including nil amounts" do
      expect(described_class.get_membership_subscription_count).to include(
        "Monthly" => 1, "Monthly (Discounted)" => 2
      )
      expect(described_class.get_membership_subscription_dollars).to include(
        "Monthly" => 25.0, "Monthly (Discounted)" => 10.0
      )
    end

    it "returns zero-filled rental reports" do
      expect(described_class.get_rental_count).to eq("Shelf" => 0, "Locker" => 1, "Plot" => 0)
      expect(described_class.get_rental_dollars).to eq("Shelf" => 0.0, "Locker" => 0.0, "Plot" => 0.0)
    end

    it "retains settlement dates for CSV exports" do
      path = Rails.root.join("tmp", "invoice-analytics-#{SecureRandom.hex}.csv")
      described_class.csv_by_date(described_class.get_membership_subscriptions, path)

      expect(File.read(path)).to include(Time.current.strftime("%m/%d/%Y"))
    ensure
      File.delete(path) if path && File.exist?(path)
    end

    it "finds invoices with a refund requested but not yet completed" do
      Invoice.collection.insert_many([
        { plan_id: "membership-one-month-recurring", amount: 50.0, refunded: false, refund_requested: Time.current },
        { plan_id: "membership-one-month-recurring", amount: 60.0, refunded: true, refund_requested: Time.current },
        { plan_id: "membership-one-month-recurring", amount: 70.0, refunded: false }
      ])

      expect(described_class.query_refunds_pending.pluck(:amount)).to eq([50.0])
    end

    it "computes invoice summary counters in one aggregation" do
      member = create(:member, expirationTime: 1.month.from_now.to_i * 1000)
      Invoice.collection.insert_many([
        { member_id: member.id, due_date: 1.day.ago, settled_at: nil, transaction_id: nil },
        { member_id: member.id, due_date: 1.day.from_now, refunded: false, refund_requested: Time.current }
      ])

      expect(described_class.summary_counts).to eq(past_due_invoices: 1, refunds_pending: 1)
    end
  end

  describe Service::Analytics::Payments do
    before do
      Payment.collection.insert_many([
        { product: "1-MONTH SUBSCRIPTION", amount: 20.0, status: "Completed", payment_date: Time.utc(2024, 1, 31) },
        { product: "Plot 1-month Subscription", amount: 30.0, status: "Completed" },
        { product: "locker monthly", amount: nil, status: "Completed" },
        { product: "Tip jar", amount: 4.0, status: "Completed" },
        { product: nil, amount: 2.0, status: "Completed" },
        { product: "5-donation", amount: 5.0, status: "Pending" }
      ])
    end

    it "classifies case-insensitively and gives membership precedence for overlapping products" do
      expect(described_class.get_membership_subscription_count).to include("Monthly" => 2)
      expect(described_class.get_rental_count).to eq("Plot" => 0, "Shelf" => 0, "Locker" => 1)
    end

    it "sums nil amounts as zero and applies completed status to every report" do
      expect(described_class.get_rental_dollars).to eq("Plot" => 0.0, "Shelf" => 0.0, "Locker" => 0.0)
      expect(described_class.get_donation_count.values.sum).to eq(0)
    end

    it "finds uncategorized completed products without collecting ids" do
      expect(described_class.not_categorized).to contain_exactly("Tip jar", nil)
    end
    it "retains payment dates for CSV exports" do
      path = Rails.root.join("tmp", "payment-analytics-#{SecureRandom.hex}.csv")
      described_class.csv_by_date(described_class.get_membership_subscriptions, path)

      expect(File.read(path)).to include("01/31/2024")
    ensure
      File.delete(path) if path && File.exist?(path)
    end
  end
end
