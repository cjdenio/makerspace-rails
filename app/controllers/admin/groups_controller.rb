class Admin::GroupsController < AdminController
  include BraintreeGateway

  before_action :set_group, only: [:show, :update, :destroy, :add_member, :remove_member]

  # GET /api/admin/groups
  def index
    groups = Group.all
    render json: groups, each_serializer: GroupSerializer, adapter: :attributes and return
  end

  # GET /api/admin/groups/:id
  def show
    render json: @group, serializer: GroupSerializer, adapter: :attributes and return
  end

  # GET /api/admin/groups/for_member/:member_id
  # Returns the group for a given member (primary or secondary)
  def for_member
    member = Member.find(params[:member_id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: params[:member_id] }) if member.nil?

    group = member.group
    raise ::Error::NotFound.new if group.nil?

    render json: group, serializer: GroupSerializer, adapter: :attributes and return
  end

  # POST /api/admin/groups
  # Creates a new household with a primary member
  def create
    primary = Member.find(group_params[:primary_member_id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: group_params[:primary_member_id] }) if primary.nil?

    # Check primary is on a household plan
    invoice = Invoice.where(resource_class: "member", resource_id: primary.id.to_s)
                     .order_by(created_at: :desc).first
    unless invoice&.plan_id&.include?("household")
      raise ::Error::UnprocessableEntity.new("Primary member must be on a household membership plan before creating a household")
    end

    # Check primary is not already in a household
    raise ::Error::UnprocessableEntity.new("Primary member is already part of a household") if primary.groupName.present?

    group = Group.new(
      groupName: primary.id.to_s,
      groupRep:  primary.fullname,
      expiry:    primary.expirationTime
    )
    group.save!

    # Link primary member to the group
    primary.update_attributes!(groupName: primary.id.to_s)

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'household_created',
      resource_type:  'Group',
      resource_id:    group.id,
      actor:          current_member,
      subject:        primary,
      after_snapshot: { groupName: group.groupName, groupRep: group.groupRep,
                        primary_member_id: primary.id.to_s },
      slack_channel:  ::Service::SlackConnector.members_relations_channel
    )

    render json: group, serializer: GroupSerializer, adapter: :attributes, status: 201 and return
  end

  # POST /api/admin/groups/:id/add_member
  # Links a secondary member to the household
  def add_member
    secondary = Member.find(params[:secondary_member_id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: params[:secondary_member_id] }) if secondary.nil?
    raise ::Error::UnprocessableEntity.new("Member is already part of a household") if secondary.groupName.present?

    @group.add_subordinate(secondary)

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'household_member_added',
      resource_type:  'Group',
      resource_id:    @group.id,
      actor:          current_member,
      subject:        secondary,
      after_snapshot: { groupName: @group.groupName, secondary_member_id: secondary.id.to_s,
                        secondary_name: secondary.fullname },
      slack_channel:  ::Service::SlackConnector.members_relations_channel
    )

    render json: @group, serializer: GroupSerializer, adapter: :attributes and return
  end

  # DELETE /api/admin/groups/:id/remove_member
  # Removes a secondary member from the household and reverts their expiration
  def remove_member
    secondary = Member.find(params[:secondary_member_id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: params[:secondary_member_id] }) if secondary.nil?
    raise ::Error::UnprocessableEntity.new("Member is not part of this household") unless secondary.groupName == @group.groupName

    # Cancel their household subscription if they have one
    if secondary.subscription_id.present?
      ::BraintreeService::Subscription.cancel(@gateway, secondary.subscription_id)
    end

    @group.remove_subordinate(secondary)

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'household_member_removed',
      resource_type:  'Group',
      resource_id:    @group.id,
      actor:          current_member,
      subject:        secondary,
      after_snapshot: { groupName: @group.groupName, secondary_member_id: secondary.id.to_s,
                        secondary_name: secondary.fullname },
      slack_channel:  ::Service::SlackConnector.members_relations_channel
    )

    render json: @group, serializer: GroupSerializer, adapter: :attributes and return
  end

  # DELETE /api/admin/groups/:id
  # Dissolves the entire household, reverts all members
  def destroy
    before = @group.attributes.dup

    # Revert all secondary members
    @group.active_members.where(:id.ne => @group.groupName).each do |m|
      @group.remove_subordinate(m)
    end

    # Unlink primary member
    primary = @group.member
    primary.update_attributes!(groupName: nil) if primary

    @group.destroy

    ::Service::AuditLogger.log(
      log_type:        'member',
      event_type:      'household_dissolved',
      resource_type:   'Group',
      resource_id:     before['_id'],
      actor:           current_member,
      subject:         primary,
      before_snapshot: before,
      after_snapshot:  {},
      slack_channel:   ::Service::SlackConnector.members_relations_channel
    )

    render json: {}, status: 204 and return
  end

  private

  def set_group
    @group = Group.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Group, { id: params[:id] }) if @group.nil?
  end

  def group_params
    params.require(:primary_member_id)
    params.permit(:primary_member_id)
  end
end
