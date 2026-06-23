class Messages::Instagram::MessageBuilder < Messages::Instagram::BaseMessageBuilder
  def initialize(messaging, inbox, outgoing_echo: false)
    super(messaging, inbox, outgoing_echo: outgoing_echo)
  end

  private

  def get_story_object_from_source_id(source_id)
    # Hub mode: roteia pelo proxy /meta do EvoHub com Bearer {channel_token} (o
    # access_token direto no Graph é o channel_token opaco → 190 → authorization_error!
    # travava a mensagem). Direto-no-Meta mantém o ?access_token= de sempre.
    if MetaBaseUrl.enabled?
      url = "#{MetaBaseUrl.for(:instagram)}/#{source_id}?fields=story,from"
      response = HTTParty.get(url, headers: hub_auth_headers)
    else
      url = "#{base_uri}/#{source_id}?fields=story,from&access_token=#{@inbox.channel.access_token}"
      response = HTTParty.get(url)
    end

    return JSON.parse(response.body).with_indifferent_access if response.success?

    # Create message first if it doesn't exist
    @message ||= conversation.messages.create!(message_params)
    handle_error_response(response)
    nil
  end

  def handle_error_response(response)
    parsed_response = JSON.parse(response.body)
    error_code = parsed_response.dig('error', 'code')

    # https://developers.facebook.com/docs/messenger-platform/error-codes
    # Access token has expired or become invalid.
    channel.authorization_error! if error_code == 190

    # There was a problem scraping data from the provided link.
    # https://developers.facebook.com/docs/graph-api/guides/error-handling/ search for error code 1609005
    if error_code == 1_609_005
      @message.attachments.destroy_all
      @message.update!(content: I18n.t('conversations.messages.instagram_deleted_story_content'))
    end

    Rails.logger.error("[InstagramStoryFetchError]: #{parsed_response.dig('error', 'message')} #{error_code}")
  end

  def base_uri
    "https://graph.instagram.com/#{GlobalConfigService.load('INSTAGRAM_API_VERSION', 'v23.0')}"
  end

  # Bearer do proxy /meta do EvoHub (Hub-ON exige Authorization header; rejeita query).
  # Token = evolution_hub_meta['channel_token'] (o getter access_token é sobrescrito).
  def hub_auth_headers
    token = (@inbox.channel.evolution_hub_meta || {})['channel_token']
    { 'Authorization' => "Bearer #{token}" }
  end
end
