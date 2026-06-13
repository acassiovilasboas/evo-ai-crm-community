# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe 'Api::V1::ProductsController#bulk', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let!(:user) { User.create!(name: 'Bulk Test User', email: "products-bulk-#{SecureRandom.hex(4)}@example.com") }

  let(:permission_check_url) { "#{base_url}/api/v1/users/#{user.id}/check_permission" }

  around do |example|
    original_base_url = ENV.fetch('EVO_AUTH_SERVICE_URL', nil)
    ENV['EVO_AUTH_SERVICE_URL'] = base_url
    Rails.cache.clear
    Current.reset
    example.run
    Rails.cache.clear
    Current.reset
    ENV['EVO_AUTH_SERVICE_URL'] = original_base_url
  end

  def stub_auth_ok
    stub_request(:post, validate_url)
      .with(headers: { 'Authorization' => "Bearer #{token}" })
      .to_return(
        status: 200,
        body: { success: true, data: { user: { id: user.id, email: user.email } } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end

  def stub_permission(granted:)
    stub_request(:post, permission_check_url)
      .to_return(
        status: 200,
        body: { success: true, data: { has_permission: granted } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
  end

  def valid_item(idx)
    {
      name: "Product #{idx}",
      kind: 'physical',
      sku: "BULK-#{idx}-#{SecureRandom.hex(3)}"
    }
  end

  context 'when payload is valid' do
    before do
      stub_auth_ok
      stub_permission(granted: true)
      Current.user = user
    end

    it 'AC1 — creates 1 product successfully (201)' do
      expect do
        post '/api/v1/products/bulk',
             params: { products: [valid_item(1)] },
             headers: headers,
             as: :json
      end.to change(Product, :count).by(1)

      expect(response).to have_http_status(:created)
      parsed = response.parsed_body
      expect(parsed['success']).to be(true)
      expect(parsed['data'].size).to eq(1)
      expect(parsed['message']).to match(/1 products created/)
    end

    it 'AC2 — creates 500 products in a single transaction' do
      items = (1..500).map { |i| valid_item(i) }

      expect do
        post '/api/v1/products/bulk',
             params: { products: items },
             headers: headers,
             as: :json
      end.to change(Product, :count).by(500)

      expect(response).to have_http_status(:created)
      parsed = response.parsed_body
      expect(parsed['data'].size).to eq(500)
    end

    it 'AC8 — allows multiple items without SKU (partial unique index) and normalises blank SKU to nil' do
      # M3 hardening: two items with sku: "" would otherwise hit PG::UniqueViolation
      # because the partial index covers non-NULL "" — importer normalises blank → nil.
      items = [
        { name: 'No SKU 1', kind: 'physical' },
        { name: 'No SKU 2', kind: 'physical', sku: '' },
        { name: 'No SKU 3', kind: 'physical', sku: '' },
        { name: 'No SKU 4', kind: 'physical', sku: nil }
      ]

      expect do
        post '/api/v1/products/bulk',
             params: { products: items },
             headers: headers,
             as: :json
      end.to change(Product, :count).by(4)

      expect(response).to have_http_status(:created)
    end

    it 'M2 — non-Hash array element yields structured 422 (not a 500)' do
      items = ['not-a-hash', { name: 'OK', kind: 'physical' }]

      expect do
        post '/api/v1/products/bulk',
             params: { products: items },
             headers: headers,
             as: :json
      end.not_to change(Product, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      details = response.parsed_body['error']['details']
      offender = details.find { |d| d['index'] == 0 }
      expect(offender['errors']['base']).to include('item must be a JSON object')
    end

    it 'M5 — pre-validation reports type errors AND intra-batch SKU dupes in the same response' do
      items = [
        'junk',                                  # type error at index 0
        { name: 'A', kind: 'physical', sku: 'X' }, # ok
        { name: 'B', kind: 'physical', sku: 'X' }  # dup at index 2
      ]

      expect do
        post '/api/v1/products/bulk',
             params: { products: items },
             headers: headers,
             as: :json
      end.not_to change(Product, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      details = response.parsed_body['error']['details']

      type_err = details.find { |d| d['index'] == 0 }
      expect(type_err['errors']['base']).to include('item must be a JSON object')

      dup_err = details.find { |d| d['index'] == 2 }
      expect(dup_err['errors']['sku']).to include('duplicated within batch')
    end

    it 'AC9 — applies labels via update_labels (atomic in same transaction)' do
      items = [{ name: 'Labelled', kind: 'physical', labels: %w[promo novo] }]

      post '/api/v1/products/bulk',
           params: { products: items },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:created)
      created = Product.order(created_at: :desc).first
      expect(created.label_list.sort).to eq(%w[novo promo])
    end
  end

  context 'with size violations' do
    before do
      stub_auth_ok
      stub_permission(granted: true)
      Current.user = user
    end

    it 'AC3 — returns 422 VALIDATION_ERROR when products array is empty' do
      post '/api/v1/products/bulk',
           params: { products: [] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      parsed = response.parsed_body
      expect(parsed['success']).to be(false)
      expect(parsed['error']['code']).to eq('VALIDATION_ERROR')
      expect(parsed['error']['message']).to match(/required/i)
    end

    it 'AC3b — returns 422 VALIDATION_ERROR when products key is missing' do
      post '/api/v1/products/bulk',
           params: {},
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']['code']).to eq('VALIDATION_ERROR')
    end

    it 'AC4 — returns 422 LIMIT_EXCEEDED when payload > 500 items' do
      items = (1..501).map { |i| valid_item(i) }

      expect do
        post '/api/v1/products/bulk',
             params: { products: items },
             headers: headers,
             as: :json
      end.not_to change(Product, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      parsed = response.parsed_body
      expect(parsed['error']['code']).to eq('LIMIT_EXCEEDED')
      expect(parsed['error']['message']).to match(/500/)
      expect(parsed['error']['details']['max']).to eq(500)
      expect(parsed['error']['details']['received']).to eq(501)
    end
  end

  context 'when validation fails (rollback)' do
    before do
      stub_auth_ok
      stub_permission(granted: true)
      Current.user = user
    end

    it 'AC5 — invalid item in the middle aborts the whole batch' do
      items = [
        valid_item(1),
        valid_item(2),
        { kind: 'physical', sku: 'NO-NAME' }, # name blank → invalid
        valid_item(4),
        valid_item(5)
      ]

      expect do
        post '/api/v1/products/bulk',
             params: { products: items },
             headers: headers,
             as: :json
      end.not_to change(Product, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      parsed = response.parsed_body
      expect(parsed['error']['code']).to eq('VALIDATION_ERROR')
      details = parsed['error']['details']
      expect(details).to be_an(Array)
      offender = details.find { |d| d['index'] == 2 }
      expect(offender).to be_present
      expect(offender['sku']).to eq('NO-NAME')
      expect(offender['errors']).to have_key('name')
    end

    it 'AC6 — SKU conflict vs existing DB row aborts batch' do
      Product.create!(name: 'Existing', kind: 'physical', sku: 'EXISTS-001')
      items = [
        valid_item(1),
        { name: 'Conflict', kind: 'physical', sku: 'EXISTS-001' }
      ]

      expect do
        post '/api/v1/products/bulk',
             params: { products: items },
             headers: headers,
             as: :json
      end.not_to change(Product, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      offender = response.parsed_body['error']['details'].find { |d| d['sku'] == 'EXISTS-001' }
      expect(offender).to be_present
      expect(offender['errors']['sku'].join(' ')).to match(/taken/i)
    end

    it 'AC7 — duplicated SKU within the batch is reported at the 2nd occurrence' do
      items = [
        { name: 'A', kind: 'physical', sku: 'DUP-001' },
        { name: 'B', kind: 'physical' },
        { name: 'C', kind: 'physical' },
        { name: 'D', kind: 'physical', sku: 'DUP-001' }
      ]

      expect do
        post '/api/v1/products/bulk',
             params: { products: items },
             headers: headers,
             as: :json
      end.not_to change(Product, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      details = response.parsed_body['error']['details']
      offender = details.find { |d| d['index'] == 3 }
      expect(offender).to be_present
      expect(offender['sku']).to eq('DUP-001')
      expect(offender['errors']['sku']).to include('duplicated within batch')
    end

    it 'AC13 — atomicity: no taggings leak when batch aborts mid-loop' do
      taggings_before = ActsAsTaggableOn::Tagging.count
      items = [
        { name: 'With labels', kind: 'physical', labels: %w[tag-a tag-b] },
        { kind: 'physical' } # name blank → triggers rollback after first label was attempted
      ]

      expect do
        post '/api/v1/products/bulk',
             params: { products: items },
             headers: headers,
             as: :json
      end.not_to change(Product, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(ActsAsTaggableOn::Tagging.count).to eq(taggings_before)
    end
  end

  context 'when authn/authz checks run' do
    it 'AC10 — returns 403 when user lacks products.create' do
      stub_auth_ok
      stub_permission(granted: false)
      Current.user = user

      post '/api/v1/products/bulk',
           params: { products: [valid_item(1)] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'AC11 — returns 401 when no auth header is provided' do
      post '/api/v1/products/bulk',
           params: { products: [valid_item(1)] },
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  context 'with rate-limit (Rack::Attack)' do
    before do
      stub_auth_ok
      stub_permission(granted: true)
      Current.user = user
      Rack::Attack.enabled = true
      Rack::Attack.reset!
    end

    after do
      Rack::Attack.enabled = false
      Rack::Attack.reset!
    end

    it 'AC12 — registers the api/v1/products/bulk throttle with sane defaults' do
      throttle = Rack::Attack.throttles['api/v1/products/bulk']
      expect(throttle).to be_present
      expect(throttle.limit).to eq(10)
      expect(throttle.period).to eq(60)
    end

    # We drive Rack::Attack directly via Rack::MockRequest because Rails request
    # specs construct a middleware stack that bypasses Rack::Attack throttles even
    # when Rack::Attack.enabled is toggled at runtime (verified by tracing the throttle
    # block — it is never invoked under rspec request flow). The MockRequest path
    # exercises the *same* throttle declaration end-to-end (discriminator + counter)
    # and proves the 11th hit returns 429 in production-equivalent code paths.
    #
    # We swap the cache store to MemoryStore here because the production store
    # ($velma + redis-namespace) is incompatible with Rack::Attack::Cache#increment
    # under direct invocation — that's a known wiring quirk and unrelated to the
    # throttle declaration itself.
    context 'when driven via Rack::MockRequest' do
      let(:downstream_app) { ->(_env) { [200, {}, ['ok']] } }
      let(:mock_session) { Rack::MockRequest.new(Rack::Attack.new(downstream_app)) }

      around do |example|
        original_store = Rack::Attack.cache.store
        Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
        example.run
        Rack::Attack.cache.store = original_store
      end

      it 'AC12b — the 11th POST /api/v1/products/bulk returns 429' do
        headers_env = { 'HTTP_API_ACCESS_TOKEN' => 'rl-mock-evo1555' }

        10.times { mock_session.post('/api/v1/products/bulk', headers_env) }
        last = mock_session.post('/api/v1/products/bulk', headers_env)

        expect(last.status).to eq(429)
      end

      it 'AC12c — non-bulk POST /api/v1/products is not throttled (route specificity)' do
        headers_env = { 'HTTP_API_ACCESS_TOKEN' => 'rl-mock-evo1555' }

        12.times { mock_session.post('/api/v1/products', headers_env) }

        expect(mock_session.post('/api/v1/products', headers_env).status).to eq(200)
      end
    end
  end
end
