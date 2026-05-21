# frozen_string_literal: true

require 'httparty'

module EvolutionHub
  # Thin HTTParty wrapper around the Hub management API. Used by the CRM to
  # create channels + associated webhooks atomically when the operator
  # creates an Inbox with Evolution Hub enabled.
  #
  # Outbound Meta traffic does NOT pass through this client — it uses
  # MetaBaseUrl.for(...) directly so the Hub's transparent /meta/* proxy
  # sees the channel/Meta token in the Authorization header.
  class Client
    include HTTParty
    default_timeout 10

    class ConfigurationError < StandardError; end
    class RequestError < StandardError
      attr_reader :status, :body
      def initialize(message, status: nil, body: nil)
        super(message)
        @status = status
        @body = body
      end
    end

    # POST /api/v1/channels (single-shot create + webhook).
    # Returns a Hash with keys: "channel" (Hash) and optionally "webhook_id".
    def create_channel(type:, name:, external_id:, webhook_url:, webhook_secret:, webhook_events: nil)
      post_json('/api/v1/channels', {
        name: name,
        type: type,
        external_id: external_id,
        webhook_url: webhook_url,
        webhook_secret: webhook_secret,
        webhook_events: webhook_events
      }.compact)
    end

    # GET /api/v1/auth/me — used by EvolutionHubTestService and as a generic
    # "Hub is up and credentials are valid" probe.
    def get_me
      get_json('/api/v1/auth/me')
    end

    # DELETE /api/v1/channels/:id — used when an Inbox tied to a Hub channel
    # is removed in the CRM.
    def delete_channel(channel_id)
      delete_json("/api/v1/channels/#{channel_id}")
    end

    # DELETE /api/v1/webhooks/:id — used alongside delete_channel to remove
    # the paired Hub webhook the CRM created via single-shot CreateWithWebhook.
    # The Hub doesn't cascade webhook deletion when a channel is removed
    # (intentional: webhooks may be shared across channels), so the cleanup
    # has to happen here on the side that owns the lifecycle.
    def delete_webhook(webhook_id)
      delete_json("/api/v1/webhooks/#{webhook_id}")
    end

    private

    def base_url
      url = MetaBaseUrl.hub_url
      raise ConfigurationError, 'EVOLUTION_HUB_URL not configured' if url.blank?
      url
    end

    def api_key
      key = GlobalConfigService.load('EVOLUTION_HUB_API_KEY', nil)
      raise ConfigurationError, 'EVOLUTION_HUB_API_KEY not configured' if key.blank?
      key
    end

    def headers
      {
        'Authorization' => "Bearer #{api_key}",
        'Content-Type'  => 'application/json',
        'Accept'        => 'application/json'
      }
    end

    def post_json(path, body)
      response = HTTParty.post("#{base_url}#{path}", body: body.to_json, headers: headers, timeout: 10)
      handle(response, "POST #{path}")
    end

    def get_json(path)
      response = HTTParty.get("#{base_url}#{path}", headers: headers, timeout: 10)
      handle(response, "GET #{path}")
    end

    def delete_json(path)
      response = HTTParty.delete("#{base_url}#{path}", headers: headers, timeout: 10)
      handle(response, "DELETE #{path}")
    end

    def handle(response, op)
      if response.code.between?(200, 299)
        response.parsed_response
      else
        raise RequestError.new(
          "Evolution Hub #{op} failed with HTTP #{response.code}",
          status: response.code,
          body: response.body
        )
      end
    end
  end
end
