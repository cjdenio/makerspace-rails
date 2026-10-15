require 'swagger_helper'

describe 'NFC card management', type: :request do
  let(:admin) { create(:member, :admin, expirationTime: 1.day.from_now.to_i * 1000) }
  let(:holder) { create(:member, expirationTime: 1.day.from_now.to_i * 1000) }
  let(:card) { create(:card, member: holder, uid: '1B1A4D2F') }
  before { sign_in admin }

  path '/admin/cards/lookup' do
    get 'Look up an NFC or exact assigned legacy UID (active admin or board)' do
      tags 'Cards'
      security [sessionAuth: []]
      operationId 'adminLookupNfcCard'
      produces 'application/json'
      parameter name: :uid, in: :query, required: true, description: 'Exact card UID, including assigned legacy values. No case folding or normalization. Unknown UIDs must be uppercase hexadecimal ASCII byte pairs.', schema: { type: :string }
      let(:uid) { card.uid }
      response '200', 'Card found; member profile not embedded' do
        schema type: :object, required: %w[id uid releasable version], properties: {
          id: { type: :string }, uid: { type: :string }, holder: { type: :string, nullable: true },
          expiry: { type: :integer, nullable: true }, validity: { type: :string, nullable: true },
          member_id: { type: :string, nullable: true }, releasable: { type: :boolean },
          release_reason: { type: :string, nullable: true }, version: { type: :string }
        }
        run_test! do |response|
          expect(JSON.parse(response.body)).not_to have_key('member')
          expect(JSON.parse(response.body)['member_id']).to eq(holder.id.to_s)
          expect(response.headers['Cache-Control']).to include('no-store')
        end
      end
      response '404', 'Unknown canonical UID' do
        schema '$ref' => '#/components/schemas/error'
        let(:uid) { '0000' }
        run_test!
      end
      response '422', 'Unknown noncanonical UID or invalid parameter' do
        schema anyOf: [
          { '$ref' => '#/components/schemas/error' },
          { type: :object, required: ['error'], properties: { error: { type: :string } } }
        ]
        let(:uid) { '1b:1a:4d:2f' }
        run_test!
      end
      response '403', 'Not an active admin or board member' do
        schema '$ref' => '#/components/schemas/error'
        before { sign_in holder }
        run_test!
      end
      response '409', 'Ambiguous duplicate UID records' do
        schema type: :object, required: ['error'], properties: { error: { type: :string } }
        before { allow(CardManagement).to receive(:snapshot).and_raise(CardManagement::Conflict, 'Duplicate UID records require administrator repair.') }
        run_test!
      end
      response '401', 'Unauthenticated' do
        schema '$ref' => '#/components/schemas/error'
        before { sign_out admin }
        run_test!
      end
    end
  end

  it 'allows board lookup and rejects resource managers and expired administrators' do
    card
    admin.update!(role: 'board_member')
    get '/api/admin/cards/lookup', params: { uid: card.uid }
    expect(response).to have_http_status(:ok)
    admin.update!(role: 'resource_manager')
    get '/api/admin/cards/lookup', params: { uid: card.uid }
    expect(response).to have_http_status(:forbidden)
    admin.update!(role: 'admin', expirationTime: 1.day.ago.to_i * 1000)
    get '/api/admin/cards/lookup', params: { uid: card.uid }
    expect(response).to have_http_status(:forbidden)
  end

  [nil, 'nfc', 'import', 'other'].each do |source|
    it "rejects unobserved noncanonical UIDs regardless of source #{source.inspect}" do
      expect(CardManagement).not_to receive(:assign!)
      payload = { memberId: holder.id.to_s, uid: '1b:1a:4d:2f' }
      payload[:source] = source unless source.nil?
      post '/api/admin/cards', params: payload, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "rejects expired operators regardless of source #{source.inspect}" do
      admin.set(expirationTime: 1.day.ago.to_i * 1000)
      expect(CardManagement).not_to receive(:assign!)
      payload = { memberId: holder.id.to_s, uid: '001B1A4D2F' }
      payload[:source] = source unless source.nil?
      post '/api/admin/cards', params: payload, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  %w[legacy-key 1b:1a:4d:2f].each do |uid|
    it "looks up the exact assigned legacy UID #{uid} without requiring transactions" do
      legacy = create(:card, member: holder, uid: uid)
      get '/api/admin/cards/lookup', params: { uid: uid }
      expect(response).to have_http_status(:ok)
      snapshot = JSON.parse(response.body)
      expect(snapshot['id']).to eq(legacy.id.to_s)
      expect(snapshot['uid']).to eq(uid)
      expect(snapshot['version']).to eq(CardManagement.version(legacy))
      expect(response.headers['Cache-Control']).to include('no-store')
    end
  end

  it 'does not normalize unknown values into an existing legacy UID' do
    create(:card, member: holder, uid: 'legacy-key')
    get '/api/admin/cards/lookup', params: { uid: 'LEGACY-KEY' }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'rejects nonstring UIDs before querying cards' do
    expect(Card).not_to receive(:where)
    get '/api/admin/cards/lookup', params: { uid: { '$ne' => '' } }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  %w[lost expired].each do |condition|
    it "releases a #{condition} legacy assignment using its lookup ID and version", requires_transactions: true do
      legacy = create(:card, member: holder, uid: 'legacy-key')
      if condition == 'lost'
        legacy.update!(card_location: 'lost')
      else
        holder.set(expirationTime: 1.day.ago.to_i * 1000)
      end
      get '/api/admin/cards/lookup', params: { uid: legacy.uid }
      expect(response).to have_http_status(:ok)
      snapshot = JSON.parse(response.body)
      expect(snapshot['releasable']).to be(true)
      delete "/api/admin/cards/#{snapshot['id']}", params: { version: snapshot['version'] }, as: :json
      expect(response).to have_http_status(:no_content)
      expect(Card.where(id: legacy.id)).not_to exist
      expect(AuditLog.find_by(event_type: 'card_released', resource_id: legacy.id).before_snapshot['uid']).to eq('legacy-key')
    end
  end

  it 'accepts a legacy identifier observed by a reader', requires_transactions: true do
    create(:rejection_card, uid: 'legacy-key', holder: nil, timeOf: Time.current)
    post '/api/admin/cards', params: { memberId: holder.id.to_s, uid: 'legacy-key' }, as: :json
    expect(response).to have_http_status(:ok)
    expect(Card.where(uid: 'legacy-key')).to exist
  end

  it 'does not accept stale or already claimed reader records as import evidence' do
    create(:rejection_card, uid: 'stale-key', holder: nil, timeOf: 3.days.ago)
    create(:rejection_card, uid: 'claimed-key', holder: 'Someone', timeOf: Time.current)
    expect(CardManagement).not_to receive(:assign!)
    %w[stale-key claimed-key].each do |uid|
      post '/api/admin/cards', params: { memberId: holder.id.to_s, uid: uid, source: 'import' }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  it 'accepts canonical NFC UIDs', requires_transactions: true do
    admin.update!(role: 'board_member')
    post '/api/admin/cards', params: { memberId: holder.id.to_s, uid: '001B1A4D2F', source: 'nfc' }, as: :json
    expect(response).to have_http_status(:ok)
    expect(Card.where(uid: '001B1A4D2F')).to exist
    assigned = Card.find_by(uid: '001B1A4D2F')
    expect(AuditLog.find_by(event_type: 'card_assigned', resource_id: assigned.id).slack_message)
      .to include('Card UID source: NFC scan (client-reported)')
  end

  it 'rejects revoked operators even when their expiration is in the future' do
    admin.set(status: 'revoked')
    expect(CardManagement).not_to receive(:assign!)
    post '/api/admin/cards', params: { memberId: holder.id.to_s, uid: '001B1A4D2F' }, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  path '/admin/cards/{id}' do
    delete 'Release a lost card or card assigned to an expired/revoked member' do
      tags 'Cards'
      security [sessionAuth: []]
      operationId 'adminReleaseNfcCard'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :id, in: :path, type: :string, required: true
      parameter name: :releaseCard, in: :body, required: true, schema: {
        type: :object, required: ['version'], properties: { version: { type: :string } }
      }
      let(:id) { card.id.to_s }
      let(:releaseCard) { { version: CardManagement.version(card) } }
      response '204', 'Released, reusable' do
        before { card.update!(card_location: 'lost') }
        run_test!(requires_transactions: true) do
          expect(Card.where(id: id)).not_to exist
          expect(AuditLog.where(event_type: 'card_released', resource_id: card.id)).to exist
        end
      end
      response '409', 'Ineligible or changed assignment' do
        schema type: :object, required: ['error'], properties: { error: { type: :string } }
        run_test!(requires_transactions: true)
      end
      response '403', 'Not an active admin or board member' do
        schema '$ref' => '#/components/schemas/error'
        before { sign_in holder }
        run_test!
      end
      response '401', 'Unauthenticated' do
        schema '$ref' => '#/components/schemas/error'
        before { sign_out admin }
        run_test!
      end
      response '404', 'Card no longer exists' do
        schema '$ref' => '#/components/schemas/error'
        let(:id) { BSON::ObjectId.new.to_s }
        run_test!(requires_transactions: true)
      end
      response '422', 'Missing version' do
        schema '$ref' => '#/components/schemas/error'
        let(:releaseCard) { {} }
        run_test!
      end
      response '503', 'Transaction or audit storage unavailable' do
        schema type: :object, required: ['error'], properties: { error: { type: :string } }
        before { allow(CardManagement).to receive(:release!).and_raise(CardManagement::Unavailable, 'Unavailable') }
        run_test!
      end
    end
  end
end
