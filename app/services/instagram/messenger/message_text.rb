class Instagram::Messenger::MessageText < Instagram::BaseMessageText
  private

  def ensure_contact(ig_scope_id)
    result = fetch_instagram_user(ig_scope_id)
    # Hub mode: fetch_instagram_user pula o Koala e retorna {} (o channel_token opaco
    # do EvoHub não autentica no Graph → 190 travaria a mensagem). Sem fallback, o
    # contato/contact_inbox não nasce e create_message aborta. Garante o fallback pelo
    # próprio ig_scope_id para a conversa ser criada (enrich de perfil = follow-up).
    result = { 'id' => ig_scope_id, 'name' => nil }.with_indifferent_access if result.blank?
    find_or_create_contact(result) if result.present?
  end

  def fetch_instagram_user(ig_scope_id)
    # Hub mode: page_access_token é o channel_token opaco do EvoHub — Koala bate no
    # Graph com ele → AuthenticationError 190 → authorization_error! marca o canal
    # reauthorization_required? e o MessageBuilder#perform engole a DM. Pula em Hub
    # mode (mesmo padrão de Channel::FacebookPage subscribe/unsubscribe).
    return {} if MetaBaseUrl.enabled?

    k = Koala::Facebook::API.new(@inbox.channel.page_access_token) if @inbox.facebook?
    k.get_object(ig_scope_id) || {}
  rescue Koala::Facebook::AuthenticationError => e
    handle_authentication_error(e)
    {}
  rescue StandardError, Koala::Facebook::ClientError => e
    handle_client_error(e)
    {}
  end

  def handle_authentication_error(error)
    @inbox.channel.authorization_error!
    Rails.logger.warn("Authorization error for account #{nil_id} for inbox #{@inbox.id}")
    EvolutionExceptionTracker.new(error, account: nil).capture_exception
  end

  def handle_client_error(error)
    Rails.logger.warn("[FacebookUserFetchClientError]: inbox_id #{@inbox.id}")
    Rails.logger.warn("[FacebookUserFetchClientError]: #{error.message}")
    EvolutionExceptionTracker.new(error, account: nil).capture_exception
  end

  def create_message
    return unless @contact_inbox

    Messages::Instagram::Messenger::MessageBuilder.new(@messaging, @inbox, outgoing_echo: agent_message_via_echo?).perform
  end
end
