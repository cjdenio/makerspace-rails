class Admin::EarnedMembershipsController < AdminController
  include FastQuery::MongoidQuery
  before_action :set_membership, only: [:update, :show, :suspend, :reactivate]

  def index
    memberships = EarnedMembership.all
    return render_with_total_items(query_resource(memberships), { each_serializer: EarnedMembershipSerializer, adapter: :attributes })
  end

  def show
    render json: @membership, adapter: :attributes and return
  end

  def create
    @membership = EarnedMembership.new(create_params)
    @membership.save!
    render json: @membership, adapter: :attributes and return
  end

  def update
    @membership.update!(update_params)
    @membership.reload
    render json: @membership, adapter: :attributes and return
  end

  # POST /api/admin/earned_memberships/:id/suspend
  # Deactivates without deleting -- history (requirements, reports) stays intact.
  def suspend
    @membership.suspend!(current_member)
    render json: @membership, adapter: :attributes and return
  end

  # POST /api/admin/earned_memberships/:id/reactivate
  # Rejected (422, via the global Mongoid::Errors::Validations handler) if the
  # member currently has a paid subscription -- see the model's
  # existing_subscription validation.
  def reactivate
    @membership.reactivate!(current_member)
    render json: @membership, adapter: :attributes and return
  end

  private
  def create_params
    params.require([:member_id, :requirements])
    params[:requirements_attributes] = params.delete(:requirements)
    params.permit(:member_id, requirements_attributes: [
      :name, :rollover_limit, :term_length, :target_count, :strict
    ])
  end 

  def update_params
    params.require([:requirements])
    params[:requirements_attributes] = params.delete(:requirements)
    allowed_params = params.permit(requirements_attributes: [
      :id, :name, :rollover_limit, :term_length, :target_count, :strict
    ]).to_h
    param_requirements = allowed_params[:requirements_attributes].map { |p| p[:id] }
    @membership.requirements.each { |r| allowed_params[:requirements_attributes].push({ id: r.id }) if !param_requirements.include?(r.id.as_json) }
    allowed_params
  end

  def set_membership
    @membership = EarnedMembership.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(EarnedMembership, { id: params[:id] }) if @membership.nil?
  end
end