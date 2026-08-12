class MembersController < AuthenticationController
    include FastQuery::MongoidQuery
    before_action :set_member, only: [:show, :update]

    def index
      base_query = Member.includes(:access_cards).includes(:earned_membership).includes(:slack_user).includes(:mailtrap_event)

      limited_checkout_approver_search = false

      if is_admin? || is_board_member? || is_resource_manager?
        # Admins and Resource Managers can see all members,
        # filtered to current members only when requested
        if to_bool(search_params[:current_members] || search_params[:currentMembers])
          search = base_query.where({
            :$or => [
              { :expirationTime.gte => ((Time.now + 3.days).strftime('%s').to_i * 1000) },
              { expirationTime: nil }
            ]
          })
        else
          search = base_query
        end
      elsif is_valid_checkout_approver? && (search_params[:search].present? || search_params[:seach].present?)
        search = base_query
        limited_checkout_approver_search = true
      else
        # Regular members can only see themselves
        raise Error::NotFound.new unless defined?(@current_member)
        search = base_query.where(id: current_member.id)
      end

      @members = query_resource(search)
      if limited_checkout_approver_search
        return render_with_total_items(@members, { each_serializer: LimitedMemberSerializer, adapter: :attributes })
      end

      members = @members.to_a
      return render_with_total_items(members, {
        each_serializer: MemberSummarySerializer,
        adapter: :attributes,
        mailtrap_events_by_member_id_email: mailtrap_events_by_member_id_email(members),
        include_provisioning: is_admin? || is_board_member?
      })
    end

    def show
        raise Error::NotFound.new unless defined?(@member.id)
         if @member.id == current_member.id || is_admin? || is_board_member? || is_resource_manager?
            render json: @member, serializer: MemberSerializer, adapter: :attributes,
              include_provisioning: is_admin? || is_board_member?, viewer: current_member and return
         else
             Rails.logger.warn("Calling show for #{@member.id} while logged in as #{@current_member.id}!")
             raise Error::Forbidden.new
         end
    end

    def update
        raise Error::NotFound.new unless defined?(@member.id)
        # Admins and board members can update any member, non-admins can only update themselves
        unless @member.id == current_member.id || is_admin? || is_board_member?
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
         permitted_params = member_params
         authorize_silence_emails_change!(permitted_params)

         @member.assign_attributes(permitted_params)
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
    def mailtrap_events_by_member_id_email(members)
      member_email_pairs = members.map { |member| [member.id, member.email.to_s.downcase] }
      member_ids = member_email_pairs.map(&:first)
      emails = member_email_pairs.map(&:last).reject(&:blank?)
      return {} if member_ids.empty? || emails.empty?

      MailtrapEvent
        .where(:member_id.in => member_ids, :email.in => emails)
        .desc(:occurred_at)
        .each_with_object({}) do |event, events_by_key|
          key = [event.member_id.to_s, event.email.to_s.downcase]
          events_by_key[key] ||= event
        end
    end

    def set_member
      @member = Member.find(params[:id])
      raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: params[:id] }) if @member.nil?
    end

    def signature_params
      params.permit(:signature)
    end

    def authorize_silence_emails_change!(permitted_params)
      return unless permitted_params.key?(:silence_emails)

      boolean_type = ActiveModel::Type::Boolean.new
      requested_value = boolean_type.cast(permitted_params[:silence_emails]) || false
      current_value = boolean_type.cast(@member.silence_emails) || false
      return if requested_value == current_value
      updating_self = @member.id == current_member.id

      return if updating_self && (is_admin? || is_board_member? || is_resource_manager?)

      if is_admin?
        raise Error::Forbidden.new if @member.status == 'revoked'
        return
      end

      if is_board_member?
        raise Error::Forbidden.new unless requested_value == true
        return
      end

      raise Error::Forbidden.new unless updating_self && requested_value == true
    end

    def member_params
      params.permit(:firstname, :lastname, :email, :phone, :silence_emails, address: [:street, :unit, :city, :state, :postal_code])
    end

    def search_params
      params.permit(:current_members, :currentMembers, :format, :member, :page_num, :pageNum, :order_by, :orderBy, :order, :search)
    end
end
