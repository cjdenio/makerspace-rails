class MemberMailer < ApplicationMailer

  def password_changed(member_id)
    @member = Member.find(member_id)
    @google_doc_content = ::Service::EmailTemplate.render(:password_changed, {
      member_firstname: @member.firstname,
      url: base_url
    })
    template = @google_doc_content ? "shared/google_doc_email" : "member_mailer/password_changed"
    mail to: @member.email, subject: "Your Manchester Makerspace password has been changed", template_path: "", template_name: template
  end

  def admin_password_reset(member_email, password_token)
    @reset_url = base_url + "resetPassword/#{password_token}"
    @member_email = member_email
    mail to: member_email, subject: "Reset your Manchester Makerspace password"
  end

  def welcome_email(email)
    @google_doc_content = ::Service::EmailTemplate.render(:welcome_email, {
      url: base_url
    })
    if @google_doc_content
      mail to: email, subject: "Welcome to Manchester Makerspace!", template_path: "shared", template_name: "google_doc_email"
    else
      mail to: email, subject: "Welcome to Manchester Makerspace!"
    end
  end

  def welcome_email_manual_register(member_email, password_token)
    @reset_url = base_url + "resetPassword/#{password_token}"
    @member_email = member_email
    @google_doc_content = ::Service::EmailTemplate.render(:welcome_email_manual_register, {
      member_email: member_email,
      reset_url: @reset_url
    })
    if @google_doc_content
      mail to: member_email, subject: "Welcome to Manchester Makerspace!", template_path: "shared", template_name: "google_doc_email"
    else
      mail to: member_email, subject: "Welcome to Manchester Makerspace!"
    end
  end

  def member_registered(member_id)
    @member = Member.find(member_id)
    @google_doc_content = ::Service::EmailTemplate.render(:member_registered, {
      member_name: @member.fullname
    })
    if @google_doc_content
      mail to: @member.email, cc: "contact@manchestermakerspace.org", subject: "Thank you for registering #{@member.fullname}", template_path: "shared", template_name: "google_doc_email"
    else
      mail to: @member.email, cc: "contact@manchestermakerspace.org", subject: "Thank you for registering #{@member.fullname}"
    end
  end

  def send_document(document_name, member_id, document_string)
    member = Member.find(member_id)
    attachments["#{document_name}.pdf"] = document_string
    @doc_name = document_name.titleize
    mail to: member.email, subject: "Manchester Makerspace - Signed #{@doc_name}"
  end

  def request_document(document_type, member_id)
    @member = Member.find(member_id)
    @document_type = document_type
    mail to: @member.email, subject: "Action Required - Manchester Makerspace"
  end

  def contract_updated(member_id)
    @member = Member.find(member_id)
    document_name = ::Service::GoogleDrive.get_document_name(@member, "Code of Conduct")
    pdf_string = ::Service::GoogleDrive.generate_document_string(:code_of_conduct, { member: @member })
    attachments["#{document_name}.pdf"] = pdf_string
    mail to: @member.email, subject: "Manchester Makerspace Membership Updates"
  end

  private

  def base_url
    url_for(action: :application, controller: 'application')
  end
end
