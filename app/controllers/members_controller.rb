class MembersController < AuthenticationController
    include FastQuery::MongoidQuery
    before_action :set_member, only: [:show, :update]

    def index
      base_query = Member.includes(:access_cards).includes(:earned_membership).includes(:slack_user).includes(:mailtrap_event)

      if is_admin? || is_board_member? || is_resource_manager?
        # Admins and Resource Managers can see all members,
        # filtered to current members only when requested
        if to_bool(search_params[:current_members])
          search = base_query.where({
            :$or => [
              { :expirationTime.gte => ((Time.now + 3.days).strftime('%s').to_i * 1000) },
              { expirationTime: nil }
            ]
          })
        else
          search = Mongoid::Criteria.new(base_query)
        end
      else
        # Regular members can only see themselves
        raise Error::NotFound.new unless defined?(@current_member)
        search = base_query.where(id: current_member.id)
      end

      @members = query_resource(search)
      return render_with_total_items(@members, { each_serializer: MemberSummarySerializer, adapter: :attributes })
    end

    def show
        raise Error::NotFound.new unless defined?(@member.id)
         if @member.id == current_member.id || is_admin? || is_board_member? || is_resource_manager?
            render json: @member, serializer: MemberSerializer, adapter: :attributes and return
         else
             Rails.logger.warn("Calling show for #{@member.id} while logged in as #{@current_member.id}!")
             raise Error::Forbidden.new
         end
    end

    def update
        raise Error::NotFound.new unless defined?(@member.id)
        # Admins and board members can update any member, non-admins can only update themselves
        unless @member.id == current_member.id || is_admin? || is_board_member? || is_resource_manager?
            Rails.logger.warn("Calling update for #{@member.id} while logged in as #{@current_member.id}!")
            raise Error::Forbidden.new
        end

      before = @member.attributes.dup

      if signature_params[:signature]
         encoded_signature = signature_params[:signature].split(",")[1]
         DocumentUploadJob.perform_later(encoded_signature, "member_contract", @member.id.as_json)
         @member.update_attributes!(member_contract_signed_date: Date.today)

         # Log contract signature — no Slack, pure audit trail
         Service::AuditLogger.log(
           log_type:        'member',
           event_type:      'contract_signed',
           resource_type:   'Member',
           resource_id:     @member.id,
           actor:           current_member,
           subject:         @member,
           before_snapshot: before,
           after_snapshot:  @member.reload.attributes
         )
       else
         @member.assign_attributes(member_params)
         @member.save!

         # Log member self-service update — no Slack, pure audit trail
         Service::AuditLogger.log(
           log_type:        'member',
           event_type:      'member_updated',
           resource_type:   'Member',
           resource_id:     @member.id,
           actor:           current_member,
           subject:         @member,
           field_changes:   @member.previous_changes,
           before_snapshot: before,
           after_snapshot:  @member.reload.attributes
         )
       end

       render json: @member, adapter: :attributes and return
     end

    private
    def set_member
      @member = Member.find(params[:id])
      raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: params[:id] }) if @member.nil?
    end

    def signature_params
      params.permit(:signature)
    end

    def member_params
      params.permit(:firstname, :lastname, :email, :phone, :silence_emails, address: [:street, :unit, :city, :state, :postal_code])
    end

    def search_params
      params.permit(:current_members, :format, :member, :page_num, :order_by, :order, :search)
    end
end
