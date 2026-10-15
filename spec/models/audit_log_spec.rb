require 'rails_helper'

RSpec.describe AuditLog, type: :model do
  let(:valid_attrs) do
    {
      log_type:      'member',
      event_type:    'member_updated',
      resource_type: 'Member',
      resource_id:   BSON::ObjectId.new,
      slack_message: 'Member Updated by Admin on Jane Smith\'s Member — status: activeMember → revoked'
    }
  end

  describe 'validations' do
    it 'is valid with all required fields' do
      expect(AuditLog.new(valid_attrs)).to be_valid
    end

    %i[log_type event_type resource_type resource_id slack_message].each do |field|
      it "is invalid without #{field}" do
        log = AuditLog.new(valid_attrs.except(field))
        expect(log).not_to be_valid
        expect(log.errors[field]).to be_present
      end
    end
  end

  describe 'optional fields' do
    it 'persists with all optional fields nil' do
      log = AuditLog.create!(valid_attrs)
      expect(log.actor_id).to be_nil
      expect(log.actor_name).to be_nil
      expect(log.subject_id).to be_nil
      expect(log.subject_name).to be_nil
      expect(log.field_changes).to be_nil
      expect(log.before_snapshot).to be_nil
      expect(log.after_snapshot).to be_nil
      expect(log.slack_channel).to be_nil
      expect(log.slack_posted).to be_nil
      expect(log.ip_address).to be_nil
    end
  end

  describe 'timestamps' do
    it 'sets created_at on save' do
      log = AuditLog.create!(valid_attrs)
      expect(log.created_at).to be_present
    end
  end
end
