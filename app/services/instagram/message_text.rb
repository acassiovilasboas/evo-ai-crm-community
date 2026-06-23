class Instagram::MessageText < Instagram::BaseMessageText
  attr_reader :messaging

  def ensure_contact(ig_scope_id)
    Rails.logger.info("[Instagram::MessageText] ensure_contact called with ig_scope_id: #{ig_scope_id}")
    result = fetch_instagram_user(ig_scope_id)
    Rails.logger.info("[Instagram::MessageText] fetch_instagram_user result: #{result.inspect}")

    # Use ig_scope_id as fallback if API didn't return user data
    if result.blank? || result['id'].blank?
      Rails.logger.warn('[Instagram::MessageText] fetch_instagram_user returned empty result or nil id, using ig_scope_id as fallback')
      result = { 'id' => ig_scope_id, 'name' => nil }.with_indifferent_access
    end

    Rails.logger.info("[Instagram::MessageText] Calling find_or_create_contact with result: #{result.inspect}")
    find_or_create_contact(result)
    Rails.logger.info("[Instagram::MessageText] After find_or_create_contact, contact_inbox: #{@contact_inbox.inspect}")
  end

  # Hub mode: access_token é o channel_token opaco do EvoHub → graph.instagram.com dá
  # 190 → authorization_error! prende o canal e o MessageBuilder#perform engole a DM.
  # Pula o enrich (ensure_contact cai no fallback {id: ig_scope_id}); enrich via proxy
  # do Hub = follow-up. Mesmo padrão de subscribe/unsubscribe no Channel::Instagram.
  def fetch_instagram_user(ig_scope_id)
    return {} if MetaBaseUrl.enabled?

    # Use only fields that are available for regular Instagram users
    # profile_picture_url is the correct field name (not profile_pic)
    # Some fields like follower_count may not be available for all user types
    fields = 'id,name,username,profile_pic'
    url = "#{base_uri}/#{ig_scope_id}?fields=#{fields}&access_token=#{@inbox.channel.access_token}"

    Rails.logger.info("[Instagram::MessageText] Fetching user data from Instagram API - ig_scope_id: #{ig_scope_id}, url: #{url.gsub(
      /access_token=[^&]+/, 'access_token=[FILTERED]'
    )}")
    response = HTTParty.get(url)

    Rails.logger.info("[Instagram::MessageText] Instagram API response - status: #{response.code}, success?: #{response.success?}, body: #{response.body.inspect}")

    if response.success?
      # Check if response body is empty or just {}
      parsed_body = begin
        JSON.parse(response.body)
      rescue StandardError
        {}
      end
      if parsed_body.blank? || parsed_body == {}
        Rails.logger.warn("[Instagram::MessageText] Instagram API returned empty response (status 200) - this usually means user consent is required or token lacks permissions. User ID: #{ig_scope_id}")
        return {}
      end

      # Check if there's an error in the response even with status 200
      if parsed_body['error'].present?
        Rails.logger.warn("[Instagram::MessageText] Instagram API returned error in successful response: #{parsed_body['error'].inspect}")
        handle_error_response(response)
        return {}
      end

      result = process_successful_response(response)
      Rails.logger.info("[Instagram::MessageText] Processed successful response: #{result.inspect}")
      return result
    end

    handle_error_response(response)
    {}
  end

  def process_successful_response(response)
    result = JSON.parse(response.body).with_indifferent_access
    {
      'id' => result['id'],
      'name' => result['name'],
      'username' => result['username'],
      'profile_pic' => result['profile_picture_url'], # Map profile_picture_url to profile_pic for compatibility
      'profile_picture_url' => result['profile_picture_url']
    }.with_indifferent_access
  end

  def handle_error_response(response)
    parsed_response = response.parsed_response
    error_message = parsed_response.dig('error', 'message')
    error_code = parsed_response.dig('error', 'code')

    Rails.logger.warn("[Instagram::MessageText] Instagram API error - code: #{error_code}, message: #{error_message}, full_response: #{parsed_response.inspect}")

    # https://developers.facebook.com/docs/messenger-platform/error-codes
    # Access token has expired or become invalid.
    if error_code == 190
      Rails.logger.error('[Instagram::MessageText] Access token expired or invalid (error 190), marking channel as requiring reauthorization')
      channel.authorization_error!
    end

    # TODO: Remove this once we have a better way to handle this error.
    # https://developers.facebook.com/docs/messenger-platform/instagram/features/user-profile/#user-consent
    # The error typically occurs when the connected Instagram account attempts to send a message to a user
    # who has never messaged this Instagram account before.
    # We can only get consent to access a user's profile if they have previously sent a message to the connected Instagram account.
    # In such cases, we receive the error "User consent is required to access user profile".
    # We can safely ignore this error.
    if error_code == 230
      Rails.logger.info('[Instagram::MessageText] User consent required (error 230) - this is expected for first-time users. Using ig_scope_id as fallback.')
      return
    end

    Rails.logger.warn("[InstagramUserFetchError]: inbox_id #{@inbox.id}")
    Rails.logger.warn("[InstagramUserFetchError]: #{error_message} #{error_code}")

    exception = StandardError.new("#{error_message} (Code: #{error_code})")
    EvolutionExceptionTracker.new(exception, account: nil).capture_exception
  end

  def base_uri
    "https://graph.instagram.com/#{GlobalConfigService.load('INSTAGRAM_API_VERSION', 'v23.0')}"
  end

  def create_message
    Rails.logger.info("[Instagram::MessageText] create_message called - contact_inbox: #{@contact_inbox.inspect}")

    unless @contact_inbox
      Rails.logger.warn('[Instagram::MessageText] contact_inbox is nil, cannot create message')
      return
    end

    Rails.logger.info('[Instagram::MessageText] Creating message via MessageBuilder')
    result = Messages::Instagram::MessageBuilder.new(@messaging, @inbox, outgoing_echo: agent_message_via_echo?).perform
    Rails.logger.info("[Instagram::MessageText] MessageBuilder result: #{result.inspect}")
    result
  end
end
