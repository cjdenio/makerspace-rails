class Admin::VolunteerTasksController < AdminOrRmController
  MUTATION_ACTIONS = [
    :update,
    :destroy,
    :complete,
    :cancel,
    :release,
    :reject_pending,
    :reset_cooldown
  ].freeze

  before_action :find_task, only: MUTATION_ACTIONS
  before_action :authorize_current_task_shop!, only: MUTATION_ACTIONS

  # GET /api/admin/volunteer_tasks
  def index
    tasks = VolunteerTask.all.order_by(created_at: :desc)
    tasks = tasks.where(status: params[:status])                  if params[:status].present?
    tasks = tasks.where(parent_task_id: params[:parent_task_id])  if params[:parent_task_id].present?
    tasks = tasks.where(:parent_task_id.ne => nil)                if params[:children_only] == 'true'
    tasks = tasks.where(parent_task_id: nil)                      if params[:parents_only] == 'true'
    render json: tasks, each_serializer: VolunteerTaskSerializer, adapter: :attributes
  end

  # POST /api/admin/volunteer_tasks
  def create
    authorize_shop_assignment!(task_params[:shop_id])
    task = VolunteerTask.new(task_params.merge(
      created_by_id: current_member.id,
      credit_value:  task_params[:credit_value]&.to_f || 1.0
    ))
    task.save!
    enqueue_canvas_sync(task.shop_id)
    render json: task, serializer: VolunteerTaskSerializer, adapter: :attributes
  end

  # PUT /api/admin/volunteer_tasks/:id
  def update
    if task_params.key?(:shop_id)
      authorize_shop_assignment!(task_params[:shop_id])
    end
    previous_shop_id = @task.shop_id
    @task.update!(task_params)
    enqueue_canvas_sync(previous_shop_id)
    enqueue_canvas_sync(@task.shop_id) if @task.shop_id.to_s != previous_shop_id.to_s
    render json: @task, serializer: VolunteerTaskSerializer, adapter: :attributes
  end

  # POST /api/admin/volunteer_tasks/:id/complete
  def complete
    if @task.claimed_by_id.present?
      claimant = Member.find(@task.claimed_by_id)
      if claimant.nil? || !claimant.active_membership_status?
        render json: { error: 'Cannot approve credit for a member who is not an active member' }, status: :forbidden and return
      end
    end
    @task.complete!(current_member)
    render json: @task, serializer: VolunteerTaskSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'You cannot verify your own task completion' }, status: :forbidden
  end

  # POST /api/admin/volunteer_tasks/:id/release
  def release
    raise ::Error::UnprocessableEntity.new('A reason is required') unless params[:reason].present?
    @task.release!(current_member, params[:reason])
    render json: @task, serializer: VolunteerTaskSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'You cannot release your own claimed task' }, status: :forbidden
  end

  # POST /api/admin/volunteer_tasks/:id/reject_pending
  def reject_pending
    raise ::Error::UnprocessableEntity.new('A reason is required') unless params[:reason].present?
    @task.reject_pending!(current_member, params[:reason])
    render json: @task, serializer: VolunteerTaskSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'You cannot reject your own task' }, status: :forbidden
  end

  # POST /api/admin/volunteer_tasks/:id/cancel
  def cancel
    @task.cancel!
    enqueue_canvas_sync(@task.shop_id)
    render json: @task, serializer: VolunteerTaskSerializer, adapter: :attributes
  end

  # POST /api/admin/volunteer_tasks/:id/reset_cooldown
  def reset_cooldown
    unless @task.status == 'recurring'
      render json: { error: 'Only recurring tasks have a cooldown to reset' }, status: :unprocessable_content and return
    end
    @task.update!(next_available: nil, claimed_at: nil)
    render json: @task, serializer: VolunteerTaskSerializer, adapter: :attributes
  end

  # DELETE /api/admin/volunteer_tasks/:id
  def destroy
    raise ::Error::Forbidden.new unless is_admin? || is_board_member?
    shop_id = @task.shop_id
    @task.destroy
    enqueue_canvas_sync(shop_id)
    render json: {}, status: :no_content
  end

  private

  def find_task
    @task = VolunteerTask.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(VolunteerTask, { id: params[:id] }) if @task.nil?
  end

  def authorize_current_task_shop!
    authorize_shop_assignment!(@task.shop_id)
  end

  def task_params
    params.permit(
      :title,
      :description,
      :credit_value,
      :shop_id,
      :status,
      :days,
      prerequisite_tool_ids: []
    )
  end

  def authorize_shop_assignment!(shop_id)
    return if VolunteerAdministrationAuthorization.allowed?(current_member, shop_id)

    raise ::Error::Forbidden.new
  end

  def enqueue_canvas_sync(shop_id)
    return if shop_id.blank?

    VolunteerSlackCanvasSyncJob.perform_later(shop_id.to_s)
  end
end
