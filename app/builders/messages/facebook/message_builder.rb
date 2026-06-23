# This class creates both outgoing messages from Evolution and echo outgoing messages based on the flag `outgoing_echo`
# Assumptions
# 1. Incase of an outgoing message which is echo, source_id will NOT be nil,
#    based on this we are showing "not sent from Evolution" message in frontend
#    Hence there is no need to set user_id in message for outgoing echo messages.

# Load EvolutionExceptionTracker (using load to avoid Zeitwerk constant name mismatch)
load Rails.root.join('lib/evolution_exception_tracker.rb').to_s unless defined?(EvolutionExceptionTracker)

class Messages::Facebook::MessageBuilder < Messages::Messenger::MessageBuilder
  attr_reader :response

  def initialize(response, inbox, outgoing_echo: false)
    super()
    @response = response
    @inbox = inbox
    @outgoing_echo = outgoing_echo
    @sender_id = (@outgoing_echo ? @response.recipient_id : @response.sender_id)
    @message_type = (@outgoing_echo ? :outgoing : :incoming)
    @attachments = (@response.attachments || [])
  end

  def perform
    # This channel might require reauthorization, may be owner might have changed the fb password
    return if @inbox.channel.reauthorization_required?

    # Check if message already exists (prevent duplicates)
    # Multiple webhook events can be received for the same message due to Facebook retries or misconfigurations
    return if message_exists?

    ActiveRecord::Base.transaction do
      build_contact_inbox
      build_message
    end
  rescue Koala::Facebook::AuthenticationError => e
    Rails.logger.warn("Facebook authentication error for inbox: #{@inbox.id} with error: #{e.message}")
    Rails.logger.error e
    @inbox.channel.authorization_error!
  rescue StandardError => e
    EvolutionExceptionTracker.new(e, account: nil).capture_exception
    true
  end

  private

  def build_contact_inbox
    @contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: @sender_id,
      inbox: @inbox,
      contact_attributes: contact_params
    ).perform
  end

  def build_message
    @message = conversation.messages.create!(message_params)

    @attachments.each do |attachment|
      process_attachment(attachment)
    end
  end

  def message_exists?
    return false unless response.identifier.present?

    # Check if a message with this source_id already exists in any conversation for this inbox
    Message.where(inbox_id: @inbox.id)
           .where(source_id: response.identifier)
           .exists?
  end

  def conversation
    @conversation ||= set_conversation_based_on_inbox_config
  end

  def set_conversation_based_on_inbox_config
    if @inbox.lock_to_single_conversation
      # Exclude post conversations for Messenger direct messages
      # Messenger direct messages should NEVER be associated with post conversations
      found_conversation = Conversation.where(conversation_params)
                                       .where("additional_attributes->>'conversation_type' IS NULL OR additional_attributes->>'conversation_type' != ?", 'post')
                                       .order(created_at: :desc)
                                       .first

      # If found conversation is a post conversation (shouldn't happen, but double-check), create new one
      if found_conversation&.post_conversation?
        Rails.logger.warn('MessageBuilder: Found post conversation for Messenger direct message, creating new normal conversation')
        return build_conversation
      end

      found_conversation || build_conversation
    else
      find_or_build_for_multiple_conversations
    end
  end

  def find_or_build_for_multiple_conversations
    # If lock to single conversation is disabled, we will create a new conversation if previous conversation is resolved
    # Exclude post conversations for Messenger direct messages
    # Messenger direct messages should NEVER be associated with post conversations
    last_conversation = Conversation.where(conversation_params)
                                    .where.not(status: :resolved)
                                    .where("additional_attributes->>'conversation_type' IS NULL OR additional_attributes->>'conversation_type' != ?", 'post')
                                    .order(created_at: :desc)
                                    .first

    # If no normal conversation found, create a new one
    return build_conversation if last_conversation.nil?

    # Double-check: if somehow we got a post conversation, create a new normal one
    if last_conversation.post_conversation?
      Rails.logger.warn('MessageBuilder: Found post conversation for Messenger direct message, creating new normal conversation')
      return build_conversation
    end

    last_conversation
  end

  def build_conversation
    # Always create a normal conversation (not a post conversation) for Messenger direct messages
    Conversation.create!(conversation_params.merge(
                           contact_inbox_id: @contact_inbox.id,
                           additional_attributes: {}
                         ))
  end

  def location_params(attachment)
    lat = attachment['payload']['coordinates']['lat']
    long = attachment['payload']['coordinates']['long']
    {
      external_url: attachment['url'],
      coordinates_lat: lat,
      coordinates_long: long,
      fallback_title: attachment['title']
    }
  end

  def fallback_params(attachment)
    {
      fallback_title: attachment['title'],
      external_url: attachment['url']
    }
  end

  def conversation_params
    {
      inbox_id: @inbox.id,
      contact_id: @contact_inbox.contact_id
    }
  end

  def message_params
    {
      inbox_id: conversation.inbox_id,
      message_type: @message_type,
      content: response.content,
      source_id: response.identifier,
      content_attributes: {
        in_reply_to_external_id: response.in_reply_to_external_id
      },
      sender: @outgoing_echo ? nil : @contact_inbox.contact
    }
  end

  def process_contact_params_result(result)
    {
      name: "#{result['first_name'] || 'John'} #{result['last_name'] || 'Doe'}",
      avatar_url: result['profile_pic']
    }
  end

  # rubocop:disable Metrics/AbcSize
  # rubocop:disable Metrics/MethodLength
  def contact_params
    # Hub mode: page_access_token é o channel_token opaco do EvoHub. O Koala bate no
    # Graph com ele → AuthenticationError 190 → authorization_error! marca o canal e
    # o perform faz `return if reauthorization_required?` → a DM do Facebook nunca
    # vira mensagem. Pula o enrich de perfil em Hub mode e usa o fallback (John Doe
    # sem avatar); enriquecer via proxy do Hub é follow-up. Mesmo motivo do IG.
    return process_contact_params_result({}) if MetaBaseUrl.enabled?

    begin
      k = Koala::Facebook::API.new(@inbox.channel.page_access_token) if @inbox.facebook?
      result = k.get_object(@sender_id) || {}
    rescue Koala::Facebook::AuthenticationError => e
      Rails.logger.warn("Facebook authentication error for inbox: #{@inbox.id} with error: #{e.message}")
      Rails.logger.error e
      @inbox.channel.authorization_error!
      raise
    rescue Koala::Facebook::ClientError => e
      result = {}
      # OAuthException, code: 100, error_subcode: 2018218, message: (#100) No profile available for this user
      # We don't need to capture this error as we don't care about contact params in case of echo messages
      if e.message.include?('2018218')
        Rails.logger.warn e
      else
        EvolutionExceptionTracker.new(e, account: nil).capture_exception unless @outgoing_echo
      end
    rescue StandardError => e
      result = {}
      EvolutionExceptionTracker.new(e, account: nil).capture_exception
    end
    process_contact_params_result(result)
  end
  # rubocop:enable Metrics/AbcSize
  # rubocop:enable Metrics/MethodLength
end
