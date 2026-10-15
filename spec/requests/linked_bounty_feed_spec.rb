require 'rails_helper'
RSpec.describe 'Linked bounty feed eligibility', type: :request do
  before { allow(Service::MemberProvisioning).to receive(:invite_slack) }
  %w[member admin board_member resource_manager].each do |role|
    it "excludes reporter and unqualified linked tasks for #{role}, preserving ordinary eligibility" do
      member = create(:member, :current, role: role)
      tool = create(:tool, shop: create(:shop))
      own_ticket = create(:fix_ticket, reporter_id: member.id)
      other_ticket = create(:fix_ticket)
      attrs = { title: 'Repair', description: 'Replace switch', credit_value: 1, shop_id: tool.shop_id }
      own = VolunteerTask.create!(**attrs, title: 'Own repair', ticket_id: own_ticket.id)
      linked = VolunteerTask.create!(**attrs, title: 'Linked repair', ticket_id: other_ticket.id, prerequisite_tool_ids: [tool.id.to_s])
      ordinary = VolunteerTask.create!(**attrs, title: 'Ordinary task', prerequisite_tool_ids: [tool.id.to_s])
      sign_in member
      get '/api/volunteer/tasks'
      expect(response).to have_http_status(:ok)
      ids = JSON.parse(response.body).map { |row| row['id'] }
      expect(ids).not_to include(own.id.to_s, linked.id.to_s)
      expect(ids.include?(ordinary.id.to_s)).to eq(role != 'member')
      tasks = WorkshopSerializer.new(tool.shop, scope: member).volunteer_tasks.index_by { |row| row[:id] }
      expect(tasks.fetch(own.id.to_s)[:eligible]).to be(false)
      expect(tasks.fetch(linked.id.to_s)[:eligible]).to be(false)
      expect(tasks.fetch(ordinary.id.to_s)[:eligible]).to eq(role != 'member')
      job = SlackVolunteerJob.new
      allow(job).to receive(:post_response)
      job.send(:handle_tasks, 'https://example.test/response', member)
      expect(job).to have_received(:post_response) do |_, _, text|
        expect(text).not_to include('Own repair', 'Linked repair')
        expect(text.include?('Ordinary task')).to eq(role != 'member')
      end
      create(:tool_checkout, member: member, tool: tool)
      expect(WorkshopSerializer.new(tool.shop, scope: member).volunteer_tasks.find { |row| row[:id] == linked.id.to_s }[:eligible]).to be(true)
      allow(job).to receive(:post_response)
      expect(job).to receive(:post_response).with(anything, :ephemeral, a_string_including('Linked repair'))
      job.send(:handle_tasks, 'https://example.test/response', member)

    end
  end
end
