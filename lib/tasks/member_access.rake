namespace :member_access do
  desc <<~DESC
    Revoke Google Drive and Slack access for a member.
    Provide one of:
      EMAIL=user@example.com
      MEMBER_ID=abc123
      NAME='First Last'

    Examples:
      rake member_access:revoke EMAIL=john@example.com
      rake member_access:revoke MEMBER_ID=5f3e2a1b4c
      rake member_access:revoke NAME='John Smith'
  DESC
  task revoke: :environment do
    member = find_member_for_revoke!

    puts "\nRevoking access for: #{member.fullname} (#{member.email})\n\n"

    results = Service::MemberAccess.revoke(member)

    puts '[Google Drive]'
    print_result(results[:gdrive_resources])
    print_result(results[:gdrive_transfer_share])

    puts "\n[Slack]"
    print_result(results[:slack])

    puts "\nDone.\n"
  end

  def find_member_for_revoke!
    member = if ENV['EMAIL'].present?
      Member.find_by(email: ENV['EMAIL'])
    elsif ENV['MEMBER_ID'].present?
      Member.find(ENV['MEMBER_ID']) rescue nil
    elsif ENV['NAME'].present?
      parts = ENV['NAME'].split(' ', 2)
      abort 'ERROR: NAME must be "First Last"' unless parts.length == 2
      Member.find_by(firstname: parts[0], lastname: parts[1])
    else
      abort 'ERROR: Provide EMAIL=, MEMBER_ID=, or NAME= argument'
    end

    abort 'ERROR: Member not found' if member.nil?
    member
  end

  def print_result(result)
    icon = case result[:status]
    when :ok        then '✅'
    when :not_found then 'ℹ️ '
    when :skipped   then '⏭️ '
    when :error     then '❌'
    end
    puts "  #{icon} #{result[:message] || result[:reason]}"
  end
end
