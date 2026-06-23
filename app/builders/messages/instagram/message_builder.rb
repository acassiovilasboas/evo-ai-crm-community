class Messages::Instagram::MessageBuilder < Messages::Instagram::BaseMessageBuilder
  def initialize(messaging, inbox, outgoing_echo: false)
    super(messaging, inbox, outgoing_echo: outgoing_echo)
  end

  private

  def get_story_object_from_source_id(source_id)
    # Hub mode: o access_token é o channel_token opaco do EvoHub — bater em
    # graph.instagram.com com ele dá 190 e dispara authorization_error! (trava a
    # mensagem). Pula o enrich de story em Hub mode (mesmo motivo do fetch de perfil
    # em Instagram::MessageText#fetch_instagram_user).
    return nil if MetaBaseUrl.enabled?

    url = "#{base_uri}/#{source_id}?fields=story,from&access_token=#{@inbox.channel.access_token}"

    response = HTTParty.get(url)

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
end
