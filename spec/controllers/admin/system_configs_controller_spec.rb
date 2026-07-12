require 'rails_helper'

RSpec.describe Admin::SystemConfigsController, type: :controller do
  set_devise_mapping

  let(:admin)  { create(:member, role: 'admin') }
  let(:member) { create(:member) }

  describe "GET #index — devise_timeout_minutes" do
    before { sign_in admin }

    it "defaults to '30' when devise_timeout_minutes has not been configured" do
      get :index, format: :json

      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response['security']['devise_timeout_minutes']).to eq('30')
    end

    it "reflects the configured value once set" do
      SystemConfig.set('devise_timeout_minutes', '45')

      get :index, format: :json

      parsed_response = JSON.parse(response.body)
      expect(parsed_response['security']['devise_timeout_minutes']).to eq('45')
    end
  end

  describe "PUT #update_setting — devise_timeout_minutes" do
    before { sign_in admin }

    it "accepts and persists a valid positive integer" do
      put :update_setting, params: { key: 'devise_timeout_minutes', value: '15' }, format: :json

      expect(response).to have_http_status(200)
      expect(SystemConfig.get('devise_timeout_minutes')).to eq('15')
    end

    it "rejects zero" do
      put :update_setting, params: { key: 'devise_timeout_minutes', value: '0' }, format: :json

      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(422)
      expect(parsed_response['error']).to eq('devise_timeout_minutes must be a positive whole number of minutes')
      expect(SystemConfig.get('devise_timeout_minutes')).to be_nil
    end

    it "rejects a negative number" do
      put :update_setting, params: { key: 'devise_timeout_minutes', value: '-5' }, format: :json

      expect(response).to have_http_status(422)
      expect(SystemConfig.get('devise_timeout_minutes')).to be_nil
    end

    it "rejects a non-integer decimal value" do
      put :update_setting, params: { key: 'devise_timeout_minutes', value: '5.5' }, format: :json

      expect(response).to have_http_status(422)
      expect(SystemConfig.get('devise_timeout_minutes')).to be_nil
    end

    it "rejects a non-numeric value" do
      put :update_setting, params: { key: 'devise_timeout_minutes', value: 'not-a-number' }, format: :json

      expect(response).to have_http_status(422)
      expect(SystemConfig.get('devise_timeout_minutes')).to be_nil
    end

    it "does not overwrite a previously valid value with a rejected update" do
      put :update_setting, params: { key: 'devise_timeout_minutes', value: '20' }, format: :json
      expect(SystemConfig.get('devise_timeout_minutes')).to eq('20')

      put :update_setting, params: { key: 'devise_timeout_minutes', value: '0' }, format: :json
      expect(response).to have_http_status(422)
      expect(SystemConfig.get('devise_timeout_minutes')).to eq('20')
    end
  end

  describe "authorization" do
    it "forbids a regular member from viewing system configs" do
      sign_in member
      get :index, format: :json
      expect(response).to have_http_status(403)
    end

    it "forbids a regular member from updating devise_timeout_minutes" do
      sign_in member
      put :update_setting, params: { key: 'devise_timeout_minutes', value: '15' }, format: :json
      expect(response).to have_http_status(403)
      expect(SystemConfig.get('devise_timeout_minutes')).to be_nil
    end
  end
end
