# frozen_string_literal: true

require 'rails_helper'

# EVO-1897 (D8): `POST /api/v1/contacts/:id/labels` must persist a tagging.
# The journeys/evo-flow add-label node authenticates server-side with the
# service token, so the request is exercised through that path here.
RSpec.describe 'Api::V1::Contacts::Labels', type: :request do
  let(:contact) { Contact.create!(name: "Repro #{SecureRandom.hex(3)}", type: 'person') }
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }
  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def json_response
    JSON.parse(response.body)
  end

  def taggings_for(record)
    ActsAsTaggableOn::Tagging.where(taggable: record)
  end

  describe 'POST /api/v1/contacts/:id/labels' do
    it 'persists a tagging when labels are sent as titles' do
      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: ['vip'] }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['payload']).to contain_exactly('vip')
      expect(taggings_for(contact).count).to eq(1)
      expect(contact.reload.label_list).to contain_exactly('vip')
    end

    it 'translates a UUID that matches a Label into its title and persists it' do
      label = Label.create!(title: 'Priority')

      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: [label.id] }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['payload']).to contain_exactly('priority')
      expect(taggings_for(contact).count).to eq(1)
    end

    # Regression: a UUID-shaped token that does not resolve to a Label row was
    # silently dropped, so `update_labels([])` wiped the list and replied 200
    # with no tagging persisted — the false-success reported in D8.
    it 'still persists a tagging when a UUID does not match any Label' do
      orphan_uuid = SecureRandom.uuid

      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: [orphan_uuid] }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['payload']).to contain_exactly(orphan_uuid)
      expect(taggings_for(contact).count).to eq(1)
      expect(contact.reload.label_list).to contain_exactly(orphan_uuid)
    end

    it 'reflects the persisted label on the subsequent index read' do
      post "/api/v1/contacts/#{contact.id}/labels",
           params: { labels: ['support'] }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)

      get "/api/v1/contacts/#{contact.id}/labels", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response['payload']).to contain_exactly('support')
    end
  end
end
