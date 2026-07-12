class Admin::VolunteerCreditsController < AdminOrRmController
  before_action :find_credit, only: [:approve, :reject, :reverse, :destroy]

  # GET /api/admin/volunteer_credits
  def index
    credits = VolunteerCredit.all.order_by(created_at: :desc)
    credits = credits.where(member_id: params[:member_id]) if params[:member_id].present?
    credits = credits.where(status: params[:status])       if params[:status].present?
    render json: credits, each_serializer: VolunteerCreditSerializer, adapter: :attributes
  end

  # POST /api/admin/volunteer_credits
  #
  # Manual credit awards (by an admin or RM) always land as 'pending'.
  # Notifications and discount-threshold checks only fire when the credit
  # is later approved via the existing approve! flow — never at creation.
  def create
    member = Member.find(credit_params[:member_id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: credit_params[:member_id] }) if member.nil?
    raise ::Error::Forbidden.new if member.id == current_member.id

    unless member.status == 'activeMember'
      render json: { error: 'Cannot award a credit to a member who is not an active member' }, status: :forbidden and return
    end

    if credit_params[:description].blank?
      render json: { error: 'Description is required' }, status: :unprocessable_content and return
    end

    credit_value = credit_params[:credit_value].to_f
    if credit_value <= 0
      render json: { error: 'Credit value must be a positive number' }, status: :unprocessable_content and return
    end

    credit = VolunteerCredit.new(
      member_id:    member.id,
      issued_by_id: current_member.id,
      description:  credit_params[:description],
      credit_value: credit_value,
      status:       'pending'
    )
    credit.save!

    render json: credit, serializer: VolunteerCreditSerializer, adapter: :attributes
  end

  # POST /api/admin/volunteer_credits/:id/approve
  def approve
    @credit.approve!(current_member)
    render json: @credit, serializer: VolunteerCreditSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'You cannot approve your own credit' }, status: :forbidden
  end

  # POST /api/admin/volunteer_credits/:id/reject
  def reject
    @credit.reject!(current_member)
    render json: @credit, serializer: VolunteerCreditSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'You cannot reject your own credit' }, status: :forbidden
  end

  # POST /api/admin/volunteer_credits/:id/reverse
  def reverse
    unless is_admin? || is_board_member?
      render json: { error: 'Only admins and board members can reverse credits' }, status: :forbidden and return
    end
    reason = params[:reason].to_s.strip
    if reason.blank?
      render json: { error: 'A reason is required to reverse a credit' }, status: :unprocessable_content and return
    end
    reversal = @credit.reverse!(current_member, reason)
    render json: reversal, serializer: VolunteerCreditSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'Unable to reverse this credit. It may already be reversed or not yet approved.' }, status: :forbidden
  end

  # DELETE /api/admin/volunteer_credits/:id
  def destroy
    raise ::Error::Forbidden.new unless is_admin? || is_board_member?
    @credit.destroy
    render json: {}, status: :no_content
  end

  private

  def find_credit
    @credit = VolunteerCredit.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(VolunteerCredit, { id: params[:id] }) if @credit.nil?
  end

  def credit_params
    params.permit(:member_id, :description, :credit_value)
  end
end
