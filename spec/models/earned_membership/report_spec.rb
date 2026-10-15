require 'rails_helper'

RSpec.describe EarnedMembership::Report, type: :model do

  describe "private methods" do
    # build(:report) uses FactoryBot build strategy which also builds (not creates)
    # the associated earned_membership. An unsaved EM has no requirements in DB,
    # so requirements_exist always fails. Fix: create EM explicitly and pass it in.

    it "validates earned_membership and report_requirements exists" do
      em = create(:earned_membership)
      requirement = create(:requirement)

      # Test 1: no earned_membership -> invalid
      report = build(:report, earned_membership: nil, report_requirements: [
        build(:report_requirement, requirement: requirement)
      ])
      expect(report.valid?).to be(false)
      report.save
      expect(report.persisted?).to be(false)

      report.earned_membership = em
      report.save
      expect(report.persisted?).to be(true)

      # Test 2: no report_requirements -> invalid
      em2 = create(:earned_membership)
      other_report = build(:report, earned_membership: em2, report_requirements: [])
      expect(other_report.valid?).to be(false)
      other_report.save
      expect(other_report.persisted?).to be(false)

      other_rr = other_report.report_requirements.build(requirement: requirement)
      other_rr.term = requirement.current_term
      expect(other_report.valid?).to be(true)
      other_report.save
      expect(other_report.persisted?).to be(true)
    end

    it "validates users dont submit reports for the future" do
      begin
        EarnedMembership::Requirement.skip_callback(:create, :before, :build_first_term)
        frozen = Time.now
        travel_to(frozen) do
          em = create(:earned_membership)
          future_term = build(:term, start_date: frozen + 1.month)
          requirement = create(:requirement, terms: [future_term])
          report = build(:report, earned_membership: em, report_requirements: [
            build(:report_requirement, requirement: requirement)
          ])
          rr = report.report_requirements.first

          expect(report.valid?).to be(false)
          report.save
          expect(report.persisted?).to be(false)

          requirement.terms.first.update(start_date: frozen - 1.second)
          requirement.reload
          rr.term = requirement.current_term
          expect(report.valid?).to be(true)
          report.save
          expect(report.persisted?).to be(true)
        end
      ensure
        EarnedMembership::Requirement.set_callback(:create, :before, :build_first_term)
      end
    end

    it "applies current term to report_requirements" do
      term = build(:term, start_date: Time.now)
      requirement = create(:requirement, terms: [term])
      report_requirement = build(:report_requirement, requirement: requirement)
      expect(report_requirement.term).to be(nil)
      report = create(:report, report_requirements: [report_requirement])
      expect(report.report_requirements.first.term).to eq(term)
    end

    it "processes report requirements" do
      term = build(:term, start_date: Time.now)
      requirement = create(:requirement, terms: [term])
      report_requirement = build(:report_requirement, requirement: requirement)
      expect(report_requirement).to receive(:update_term_count)
      report = create(:report, report_requirements: [report_requirement])
    end
  end
end
