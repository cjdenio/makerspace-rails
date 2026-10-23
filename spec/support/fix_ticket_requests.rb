if defined?(RSpec)
  RSpec.shared_context 'authenticated ticket request' do
    before do
      ActiveJob::Base.queue_adapter = :test
      allow(REDIS).to receive(:set).and_return(true)
      allow(REDIS).to receive(:eval).and_return(1)
      sign_in member
    end
  end
end
