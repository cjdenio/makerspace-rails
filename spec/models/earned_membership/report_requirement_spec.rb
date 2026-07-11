require 'rails_helper'

RSpec.describe EarnedMembership::ReportRequirement, type: :model do

  describe "public methods" do
    it "updates term count" do
    end
  end

  describe "private methods" do
    # build(:report) uses FactoryBot build strategy which also builds (not creates)
    # the associated earned_membership. An unsaved EM has no requirements in the DB,
    # so requirements_exist validation always fails. Fix: create the EM explicitly
    # so it's persisted with requirements before building the report.

    it "validates requirement exists" do
      em = create(:earned_membership)
      requirement = create(:requirement)
      report = build(:report, earned_membership: em, report_requirements: [
        build(:report_requirement_with_term, requirement: nil)
      ])
      rr = report.report_requirements.first

      expect(rr.valid?).to be(false)
      report.save
      expect(report.persisted?).to be(false)

      rr.requirement = requirement
      rr.term        = requirement.current_term
      report.save
      expect(report.persisted?).to be(true)
      expect(rr.persisted?).to be(true)
    end

    it "validates term exists" do
      begin
        EarnedMembership::Report.skip_callback(:validation, :before, :apply_term)
        em = create(:earned_membership)
        requirement = create(:requirement, term_length: 1)
        report = build(:report, earned_membership: em, report_requirements: [
          build(:report_requirement, requirement: requirement)
        ])
        rr = report.report_requirements.first

        expect(rr.valid?).to be(false)
        report.save
        expect(report.persisted?).to be(false)

        rr.term = requirement.current_term
        report.save
        expect(report.persisted?).to be(true)
        expect(rr.persisted?).to be(true)
      ensure
        EarnedMembership::Report.set_callback(:validation, :before, :apply_term)
      end
    end
  end
end
