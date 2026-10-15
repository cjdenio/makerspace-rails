require "csv"

module Service
  module Analytics
    module Members
      # Compute all dashboard member counters in one pass over the collection.
      # The predicates mirror the public query helpers below while sharing one
      # timestamp, so all counters describe the same instant.
      def self.summary_counts(now: Time.now)
        base = query_not_landlord
        timeframe_start = now - 1.month
        now_ms = now.to_i * 1000
        active_status = { "status" => { "$in" => Member::ACTIVE_MEMBERSHIP_STATUSES } }

        facets = {
          "total_members" => count_facet(active_status.merge("expirationTime" => { "$gte" => now_ms })),
          "new_members" => count_facet(active_status.merge("startDate" => { "$gte" => timeframe_start })),
          "lost_members" => [
            { "$match" => {
              "expirationTime" => { "$gte" => timeframe_start.to_i * 1000, "$lt" => now_ms }
            } },
            { "$count" => "count" }
          ],
          "subscribed_members" => count_facet(active_status.merge(
            "expirationTime" => { "$gte" => now_ms },
            "$or" => [{ "subscription_id" => { "$ne" => nil } }, { "subscription" => true }]
          ))
        }

        result = Member.collection.aggregate([
          { "$match" => base.selector },
          { "$facet" => facets }
        ]).first || {}

        facets.keys.to_h { |key| [key.to_sym, facet_count(result, key)] }
      end

      # merged_at: nil excludes soft-deleted ("ghost"/duplicate) accounts --
      # built with a raw Mongoid::Criteria rather than Member.all, so it
      # doesn't automatically inherit Member's default_scope.
      def self.query_not_landlord(base = Mongoid::Criteria.new(Member))
        base.where(:firstname.ne => "Landlord", :lastname.ne => "Fob", merged_at: nil)
      end

      # All members current and in good standing
      def self.query_total_members(base = query_good_standing_members)
        base.where(:expirationTime.gte => (Time.now.to_i * 1000))
      end

      # Members that signed up within the timeframe
      def self.query_new_members(timeframe = 1.month, base = query_good_standing_members)
        base.where(:startDate.gte => (Time.now - timeframe))
      end

      # Members whose membership actually lapsed within the timeframe -- i.e.
      # expirationTime has already passed (not merely scheduled to expire
      # later this window). Deliberately not scoped to query_good_standing_members:
      # a lost member may already have been flipped to inactive/revoked/nonMember
      # by the time this runs, and that shouldn't hide them from this count.
      # Known gap: a member revoked early (before their paid-through date)
      # keeps their original future expirationTime, so they won't show up here
      # until that stale date arrives -- accepted as rare enough not to matter.
      def self.query_lost_members(timeframe = 1.month, base = query_not_landlord)
        now_ms = Time.now.to_i * 1000
        base.where(
          :expirationTime.gte => ((Time.now - timeframe).to_i * 1000),
          :expirationTime.lt  => now_ms
        )
      end

      # Members that are in good standing, do not have an expiration date, and have invoices pending settlement
      def self.query_membership_not_started(base = query_no_expiration)
        base.where({ :id.in => ::Service::Analytics::Invoices.query_settlement_pending.pluck(:member_id).uniq })
      end

      # Members that are in good standing, do not have an expiration date, and have no invoices pending settlement
      def self.query_no_membership(base = query_no_expiration)
        base.where({ :id.nin => ::Service::Analytics::Invoices.query_settlement_pending.pluck(:member_id).uniq })
      end
      
      # Members that do not have an expiration, regardless of whether they are waiting for orientation or haven't purchased anything
      def self.query_no_expiration(base = query_good_standing_members)
        base.in(expirationTime: ["", nil])
      end

      # Members that need to sign a member contract
      def self.query_no_member_contract(base = query_total_members)
        base.where(member_contract_signed_date: nil)
      end

      def self.query_paypal_members(base = query_total_members)
        base.where(subscription: true, :subscription_id => nil)
      end

      def self.query_braintree_members(base = query_total_members) # Controller
        base.where(
          :$or => [
            { :subscription_id.ne => nil },
            {  subscription: true }
          ])
      end

      def self.query_good_standing_members(base = query_not_landlord)
        base.where(:status.in => Member::ACTIVE_MEMBERSHIP_STATUSES)
      end

      def self.get_membership_lengths(base = query_not_landlord.where(:expirationTime.ne => nil))
        base.pluck(:startDate, :expirationTime).to_a.map do |member|
          startDate, expirationTime = member
          date1 = startDate
          date2 = Time.at(expirationTime.to_i/1000)
          [startDate.strftime("%m/%d/%Y"), ((date2.year * 12 + date2.month) - (date1.year * 12 + date1.month))]
        end
      end

      # Length in months
      def self.get_average_membership_length(base = query_not_landlord.where(:expirationTime.ne => nil))
        total_membership_length = base.pluck(:startDate, :expirationTime).to_a.reduce(0.0) do |memo, member|
          startDate, expirationTime = member
          date1 = startDate
          date2 = Time.at(expirationTime.to_i/1000)
          memo + ((date2.year * 12 + date2.month) - (date1.year * 12 + date1.month))
        end

        total_membership_length/base.size
      end

      def self.get_median_membership_length(base = query_not_landlord.where(:expirationTime.ne => nil))
        membership_lengths = base.pluck(:startDate, :expirationTime).to_a.map do |member|
          startDate, expirationTime = member
          date1 = startDate
          date2 = Time.at(expirationTime.to_i/1000)
          ((date2.year * 12 + date2.month) - (date1.year * 12 + date1.month))
        end

        sorted = membership_lengths.sort
        len = sorted.length
        (sorted[(len - 1) / 2] + sorted[len / 2]) / 2.0
      end

      def self.get_membership_per_month(base = query_not_landlord, start_date = Date.parse("08/01/2016"))
        active_members_by_month(start_date: start_date, end_date: Date.today, base: base, boundary: :start).map do |row|
          [Date.strptime(row[:date], "%Y-%m"), row[:count]]
        end
      end

      # Counts memberships at each month-end boundary with one database round-trip.
      # Member#startDate is a BSON datetime, while expirationTime is Unix time in
      # milliseconds; keep both representations explicit throughout the pipeline.
      def self.active_members_by_month(start_date:, end_date:, base: Mongoid::Criteria.new(Member).where(merged_at: nil), statuses: nil, boundary: :end)
        months = month_boundaries(start_date, end_date, boundary)
        return [] if months.empty?

        overall_match = {
          "startDate" => { "$lte" => months.last[:time] },
          "expirationTime" => { "$gte" => months.first[:milliseconds] }
        }
        overall_match["status"] = { "$in" => statuses } if statuses.present?
        selector = base.selector
        overall_match = { "$and" => [selector, overall_match] } if selector.present?

        facets = months.to_h do |month|
          [month[:key], [
            { "$match" => {
              "startDate" => { "$lte" => month[:time] },
              "expirationTime" => { "$gte" => month[:milliseconds] }
            } },
            { "$count" => "count" }
          ]]
        end

        result = Member.collection.aggregate([
          { "$match" => overall_match },
          { "$facet" => facets }
        ]).first || {}

        months.map do |month|
          { date: month[:date], count: result.fetch(month[:key], []).first&.fetch("count", 0) || 0 }
        end
      end

      # Never generates a month whose start hasn't arrived yet (a wholly
      # future month, e.g. from selecting the current year), and for the
      # current, still-in-progress month, clamps an :end boundary to right
      # now rather than that month's not-yet-reached end_of_month -- otherwise
      # "active as of Sep 30" gets checked on Sep 12, wrongly excluding members
      # who are active today but happen to expire before month-end.
      # Members lost per calendar month, symmetric with New Members per Month
      # (get_membership_per_month/member_growth) but keyed off expirationTime
      # instead of startDate. Filters strictly on expirationTime < now (not
      # just "falls within the month"), so a member who hasn't actually
      # expired yet is never counted -- including for the current, still-in-
      # progress month -- since they might still renew before it happens.
      def self.lost_members_by_month(start_date:, end_date: Date.today, base: query_not_landlord)
        effective_end_ms = [end_date.to_date.end_of_month.to_time, Time.now].min.to_i * 1000
        start_ms = start_date.to_date.beginning_of_month.to_time.to_i * 1000
        return [] if start_ms >= effective_end_ms

        pipeline = [
          { "$match" => base.selector.merge(
            "expirationTime" => { "$gte" => start_ms, "$lt" => effective_end_ms }
          ) },
          { "$addFields" => { "expirationDate" => { "$toDate" => "$expirationTime" } } },
          { "$group" => {
            "_id" => { "year" => { "$year" => "$expirationDate" }, "month" => { "$month" => "$expirationDate" } },
            "count" => { "$sum" => 1 }
          } },
          { "$sort" => { "_id.year" => 1, "_id.month" => 1 } }
        ]

        Member.collection.aggregate(pipeline).map do |r|
          { month: format("%04d-%02d", r["_id"]["year"], r["_id"]["month"]), count: r["count"] }
        end
      end

      def self.month_boundaries(start_date, end_date, boundary)
        raise ArgumentError, "boundary must be :start or :end" unless %i[start end].include?(boundary)

        cursor = start_date.to_date.beginning_of_month
        last_month = [end_date.to_date, Date.today].min.beginning_of_month
        boundaries = []
        while cursor <= last_month
          natural_boundary = (boundary == :start ? cursor : cursor.end_of_month).to_time
          boundary_time = [natural_boundary, Time.now].min
          boundaries << {
            key: "month_#{cursor.strftime('%Y_%m')}",
            date: cursor.strftime("%Y-%m"),
            time: boundary_time,
            milliseconds: boundary_time.to_i * 1000
          }
          cursor = cursor.next_month
        end
        boundaries
      end

      def self.count_facet(match)
        [{ "$match" => match }, { "$count" => "count" }]
      end

      def self.facet_count(result, key)
        result.fetch(key, []).first&.fetch("count", 0) || 0
      end
      private_class_method :month_boundaries
      private_class_method :count_facet, :facet_count
    end

    module Rentals
      def self.query_no_rental_contract(base = query_total_rentals) # Member review
        base.where(contract_on_file: false)
      end

      def self.query_expiring_rentals(base = query_total_rentals) # not used
        base.where(:expiration.lte => ((Time.now + 2.weeks).to_i * 1000))
      end

      def self.query_unsubscribed_rentals(base = query_total_rentals)
        base.where(:subscription_id => nil)
      end

      def self.query_subscribed_rentals(base = query_total_rentals) #not used
        base.where(:subscription_id.ne => nil)
      end

      def self.query_total_rentals(base = Mongoid::Criteria.new(Rental))
        base.where(:expiration.gte => (Time.now.to_i * 1000), :member_id.in => ::Service::Analytics::Members.query_good_standing_members.pluck(:id))
      end
    end

    module Invoices
      def self.summary_counts
        result = Invoice.collection.aggregate([
          { "$facet" => {
            "past_due_invoices" => [
              { "$match" => query_past_due_conditions },
              { "$lookup" => {
                "from" => Member.collection.name,
                "localField" => "member_id",
                "foreignField" => "_id",
                "as" => "member"
              } },
              { "$match" => {
                "member" => { "$elemMatch" => {
                  "firstname" => { "$ne" => "Landlord" },
                  "lastname" => { "$ne" => "Fob" },
                  "status" => { "$in" => Member::ACTIVE_MEMBERSHIP_STATUSES },
                  "expirationTime" => { "$gte" => Time.now.to_i * 1000 }
                } }
              } },
              { "$count" => "count" }
            ],
            "refunds_pending" => [
              { "$match" => query_refunds_pending.selector },
              { "$count" => "count" }
            ]
          } }
        ]).first || {}

        %w[past_due_invoices refunds_pending].to_h do |key|
          [key.to_sym, result.fetch(key, []).first&.fetch("count", 0) || 0]
        end
      end

      def self.query_past_due_conditions
        { "due_date" => { "$lt" => Time.now }, "settled_at" => nil, "transaction_id" => nil }
      end
      private_class_method :query_past_due_conditions

      RENTAL_CATEGORIES = {
        "Shelf" => ["Rental-Monthly-Small-back-shop-shelf-subscription", "rental-quarterly-recurring-back-shop-shelf-subscription", "rental-monthly-non-recurring-back-shop-shelf"],
        "Locker" => ["rental-quarterly-recurring-locker-subscription"],
        "Plot" => ["rental-monthly-2-2-plot", "rental-monthly-4-4-plot", "rental-monthly-5-10-plot", "rental-monthly-5-5-plot", "rental-monthly-5-7-plot", "rental-monthly-6-6-plot"]
      }.freeze

      MEMBERSHIP_CATEGORIES = {
        "Monthly" => ["membership-one-month-recurring"],
        "Quarterly" => ["membership-three-month-recurring-covid", "membership-three-month-recurring"],
        "Semi Annually" => ["membership-six-month-recurring"],
        "Yearly" => ["membership-twelve-month-recurring"]
      }.freeze

      def self.query_created(timeframe = 1.month, base = Mongoid::Criteria.new(Invoice)) #Invoice review
        base.where(:created_at.gt => Time.now - timeframe)
      end

      def self.query_earned(timeframe = 1.month, base = Mongoid::Criteria.new(Invoice)) #invoice review
        base.where(:settled_at.gt => Time.now - timeframe)
      end

      def self.query_past_due(base = Mongoid::Criteria.new(Invoice)) #invoice review and controller
        base.where(:due_date.lt => Time.now, settled_at: nil, transaction_id: nil, :member_id.in => ::Service::Analytics::Members.query_total_members.pluck(:id))
      end

      def self.query_refunds_pending(base = Mongoid::Criteria.new(Invoice)) #invoice review and controller
        base.where(refunded: false, :refund_requested.ne => nil)
      end

      def self.query_settlement_pending(base = Mongoid::Criteria.new(Invoice)) # invoice review
        base.where(settled_at: nil, :transaction_id.ne => nil)
      end

      def self.query_all_settled(base = Mongoid::Criteria.new(Invoice))
        base.where(:settled_at.ne => nil)
      end

      def self.get_rentals(base = query_all_settled)
        aggregate_categories(base, RENTAL_CATEGORIES)
      end

      def self.get_rental_count(base = query_all_settled)
        get_rentals(base).transform_values { |values| values[:count] }
      end

      def self.get_rental_dollars(base = query_all_settled)
        get_rentals(base).transform_values { |values| values[:total_amount] }
      end

      def self.get_membership_subscriptions(base = query_all_settled)
        categories = MEMBERSHIP_CATEGORIES.flat_map do |name, plan_ids|
          [[name, plan_ids], ["#{name} (Discounted)", plan_ids]]
        end.to_h
        aggregate_categories(base, categories, discounted: true)
      end

      def self.get_membership_subscription_count(base = query_all_settled)
        get_membership_subscriptions(base).transform_values { |values| values[:count] }
      end

      def self.get_membership_subscription_dollars(base = query_all_settled)
        get_membership_subscriptions(base).transform_values { |values| values[:total_amount] }
      end

      def self.aggregate_categories(base, categories, discounted: false)
        branches = categories.map do |name, plan_ids|
          conditions = [{ "$in" => ["$plan_id", plan_ids] }]
          if discounted
            has_discount = { "$ne" => [{ "$ifNull" => ["$discount_id", nil] }, nil] }
            conditions << (name.end_with?(" (Discounted)") ? has_discount : { "$not" => [has_discount] })
          end
          { "case" => { "$and" => conditions }, "then" => name }
        end

        rows = Invoice.collection.aggregate([
          { "$match" => base.selector },
          { "$set" => { "analytics_category" => { "$switch" => { "branches" => branches, "default" => nil } } } },
          { "$match" => { "analytics_category" => { "$ne" => nil } } },
          { "$group" => {
            "_id" => "$analytics_category",
            "count" => { "$sum" => 1 },
            "total_amount" => { "$sum" => { "$ifNull" => ["$amount", 0] } },
            "dates" => { "$push" => "$settled_at" }
          } }
        ]).to_a

        normalize(rows, categories.keys)
      end

      def self.normalize(rows, category_names)
        values = category_names.to_h { |name| [name, { count: 0, total_amount: 0.0, dates: [] }] }
        rows.each do |row|
          values[row["_id"]] = { count: row["count"], total_amount: row["total_amount"].to_f, dates: row["dates"] }
        end
        values
      end
      private_class_method :aggregate_categories, :normalize

      def self.csv_by_date(query, csv_path)
        data = query.map do |name, q|
          dates = q.is_a?(Hash) ? q.fetch(:dates) : q.pluck(:settled_at)
          [name, *dates.compact.map { |d| d.strftime("%m/%d/%Y") }]
        end
        query_to_csv(data, csv_path)
      end

      def self.query_to_csv(data, csv_path)
        max_row_size = data.max { |r1, r2| r1.size <=> r2.size }.size
        data.each { |r| r[max_row_size - 1] ||=nil }
        CSV.open(csv_path, "wb") do |csv|
          data.transpose.each { |r| csv << r }
        end
      end
    end

    module Payments
      DONATION_CATEGORIES = {
        "5" => ["5-donation"], "10" => ["10-donation"], "20" => ["20-donation"],
        "100" => ["100-donation"], "Custom" => ["custom-donation"]
      }.freeze
      MEMBERSHIP_CATEGORIES = {
        "Single Month" => ["1-month Individual Membership 1mo-Stnd"],
        "Monthly" => ["1-month Subscription", "Subscription Membership Sub-Stnd-Membership", "1-month Subscription Sub-Stnd-Membership", "1mo-Sub"],
        "Monthly (Discounted)" => ["1-month Discount Subscription", "1mo-Sub-SMS", "1mo-Stnd-SMS"],
        "Quarterly" => ["3-month Subscription", "3mo-Sub"],
        "Quarterly (Discounted)" => ["3-month Discount Subscription", "3mo-Sub-SMS"],
        "Semi Annually" => ["6mo-Sub"], "Semi Annually (Discounted)" => ["6mo-Sub-SMS"],
        "Yearly" => ["12mo-Sub"], "Yearly (Discounted)" => ["12mo-Sub-SMS"]
      }.freeze
      RENTAL_CATEGORIES = { "Plot" => "Plot", "Shelf" => "Shelf", "Locker" => "Locker" }.freeze

      def self.not_categorized(base = query_completed)
        Payment.collection.aggregate([
          { "$match" => base.selector },
          category_stage,
          { "$match" => { "analytics_category" => nil, "product" => { "$ne" => " " } } },
          { "$project" => { "_id" => 0, "product" => 1 } }
        ]).map { |row| row["product"] }
      end

      def self.query_completed(base = Mongoid::Criteria.new(Payment))
        base.where(:status => "Completed")
      end

      def self.get_donations(base = query_completed)
        aggregate_categories(base, "donation", DONATION_CATEGORIES.keys)
      end

      def self.get_donation_count(base = query_completed)
        get_donations(base).transform_values { |values| values[:count] }
      end

      def self.get_donation_dollars(base = query_completed)
        get_donations(base).transform_values { |values| values[:total_amount] }
      end

      def self.get_membership_subscriptions(base = query_completed)
        aggregate_categories(base, "membership", MEMBERSHIP_CATEGORIES.keys)
      end

      def self.get_membership_subscription_count(base = query_completed)
        get_membership_subscriptions(base).transform_values { |values| values[:count] }
      end

      def self.get_membership_subscription_dollars(base = query_completed)
        get_membership_subscriptions(base).transform_values { |values| values[:total_amount] }
      end

      def self.get_rentals(base = query_completed)
        aggregate_categories(base, "rental", RENTAL_CATEGORIES.keys)
      end

      def self.get_rental_count(base = query_completed)
        get_rentals(base).transform_values { |values| values[:count] }
      end

      def self.get_rental_dollars(base = query_completed)
        get_rentals(base).transform_values { |values| values[:total_amount] }
      end

      def self.aggregate_categories(base, type, names)
        rows = Payment.collection.aggregate([
          { "$match" => base.selector }, category_stage,
          { "$match" => { "analytics_category" => /^#{Regexp.escape(type)}:/ } },
          { "$group" => {
            "_id" => "$analytics_category",
            "count" => { "$sum" => 1 },
            "total_amount" => { "$sum" => { "$ifNull" => ["$amount", 0] } },
            "dates" => { "$push" => "$payment_date" }
          } }
        ]).to_a
        values = names.to_h { |name| [name, { count: 0, total_amount: 0.0, dates: [] }] }
        rows.each do |row|
          name = row["_id"].delete_prefix("#{type}:")
          values[name] = { count: row["count"], total_amount: row["total_amount"].to_f, dates: row["dates"] }
        end
        values
      end

      def self.category_stage
        branches = []
        # Membership wins over rentals and donations when legacy product names overlap.
        MEMBERSHIP_CATEGORIES.each do |name, keys|
          branches << regex_branch("membership:#{name}", "(#{keys.map { |key| Regexp.escape(key) }.join('|')})$")
        end
        RENTAL_CATEGORIES.each do |name, key|
          branches << regex_branch("rental:#{name}", "^#{Regexp.escape(key)}")
        end
        DONATION_CATEGORIES.each do |name, keys|
          branches << regex_branch("donation:#{name}", "(#{keys.map { |key| Regexp.escape(key) }.join('|')})$")
        end
        { "$set" => { "analytics_category" => { "$switch" => { "branches" => branches, "default" => nil } } } }
      end

      def self.regex_branch(category, regex)
        { "case" => { "$regexMatch" => { "input" => { "$ifNull" => ["$product", ""] }, "regex" => regex, "options" => "i" } }, "then" => category }
      end
      private_class_method :aggregate_categories, :category_stage, :regex_branch

      def self.csv_by_date(query, csv_path)
        data = query.map do |name, q|
          dates = q.is_a?(Hash) ? q.fetch(:dates) : q.pluck(:payment_date)
          [name, *dates.compact.map { |d| (d.kind_of?(Time) ? d : Time.parse(d.sub(/(\d+:)+\d+\s/, ""))).strftime("%m/%d/%Y") }]
        end
        query_to_csv(data, csv_path)
      end

      def self.query_to_csv(data, csv_path)
        max_row_size = data.max { |r1, r2| r1.size <=> r2.size }.size
        data.each { |r| r[max_row_size - 1] ||=nil }
        CSV.open(csv_path, "wb") do |csv|
          data.transpose.each { |r| csv << r }
        end
      end
    end
  end
end
