module ControllerMacros
  def set_devise_mapping
    before(:each) do
      @request.env["devise.mapping"] = Devise.mappings[:member]
    end
  end

  def login_admin
    before(:each) do
      @request.env["devise.mapping"] = Devise.mappings[:member]
      user = create(:member, :admin)
      sign_in user
    end
  end

  def login_resource_manager
    before(:each) do
      @request.env["devise.mapping"] = Devise.mappings[:member]
      user = create(:member, :resource_manager)
      sign_in user
    end
  end

  def login_user
    let(:current_user) { create(:member) }
    before(:each) do
      @request.env["devise.mapping"] = Devise.mappings[:member]
      sign_in current_user
    end
  end
end
