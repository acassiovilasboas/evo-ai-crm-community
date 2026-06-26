# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# EVO-1251 (story 9.4): Sendgrid::Client is pure transport over POST
# /v3/mail/send. These specs assert the payload shape (custom_args,
# bypass_unsubscribe_management, rendered html) and the response -> status map.
RSpec.describe Sendgrid::Client do
  subject(:client) { described_class.new(channel) }

  let(:mail_send_url) { 'https://api.sendgrid.com/v3/mail/send' }

  let(:channel) do
    instance_double(
      Channel::Sendgrid,
      api_key: 'SG.key-x',
      from_email: 'news@acme.com',
      from_name: 'Acme News',
      reply_to: nil,
      email_signature: nil
    )
  end
  let(:contact) { instance_double(Contact, email: 'jane@acme.com') }
  let(:conversation) do
    instance_double(
      Conversation,
      contact: contact,
      contact_id: 'contact-uuid',
      display_id: 42,
      additional_attributes: { 'mail_subject' => 'Promo' }
    )
  end
  let(:message) do
    instance_double(
      Message,
      id: 'msg-uuid',
      conversation: conversation,
      content: '<h1>Hi</h1>',
      additional_attributes: { 'campaign_id' => 'camp-uuid' }
    )
  end
  let(:status_service) { instance_double(Messages::StatusUpdateService, perform: true) }

  describe '#deliver — success (202)' do
    before { stub_request(:post, mail_send_url).to_return(status: 202, body: '') }

    it 'posts to mail/send with the channel api key, from, to, html and custom_args' do
      allow(Messages::StatusUpdateService).to receive(:new).with(message, 'sent').and_return(status_service)

      client.deliver(message: message)

      expect(a_request(:post, mail_send_url).with do |req|
        body = JSON.parse(req.body)
        personalization = body['personalizations'].first
        content = body['content'].first
        req.headers['Authorization'] == 'Bearer SG.key-x' &&
          personalization['to'] == [{ 'email' => 'jane@acme.com' }] &&
          personalization['custom_args'] == {
            'contact_id' => 'contact-uuid', 'message_id' => 'msg-uuid', 'campaign_id' => 'camp-uuid'
          } &&
          body['from'] == { 'email' => 'news@acme.com', 'name' => 'Acme News' } &&
          body['subject'] == 'Promo' &&
          content['type'] == 'text/html' &&
          content['value'].include?('<h1>Hi</h1>')
      end).to have_been_made
    end

    it 'enables mail_settings.bypass_unsubscribe_management' do
      allow(Messages::StatusUpdateService).to receive(:new).and_return(status_service)

      client.deliver(message: message)

      expect(a_request(:post, mail_send_url).with do |req|
        JSON.parse(req.body).dig('mail_settings', 'bypass_unsubscribe_management', 'enable') == true
      end).to have_been_made
    end

    it 'marks the message sent and returns success' do
      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'sent').and_return(status_service)

      result = client.deliver(message: message)

      expect(result).to include(success: true, status: 202)
    end
  end

  # EVO-1721: parity with ConversationReplyMailer#email_reply rendering
  # (markdown->HTML, HTML pass-through, channel email_signature).
  describe '#deliver — html rendering parity with SMTP path' do
    before { stub_request(:post, mail_send_url).to_return(status: 202, body: '') }

    let(:markdown_message) do
      instance_double(
        Message,
        id: 'msg-md',
        conversation: conversation,
        content: '**bold**',
        additional_attributes: nil
      )
    end

    it 'renders markdown content as HTML in the payload value' do
      allow(Messages::StatusUpdateService).to receive(:new).and_return(status_service)

      client.deliver(message: markdown_message)

      expect(a_request(:post, mail_send_url).with do |req|
        value = JSON.parse(req.body)['content'].first['value']
        value.include?('<strong>bold</strong>') && value.exclude?('**bold**')
      end).to have_been_made
    end

    it 'passes pre-rendered HTML content through without double-rendering' do
      html = '<!DOCTYPE html><html><body><p>Hi</p></body></html>'
      html_message = instance_double(
        Message, id: 'msg-html', conversation: conversation, content: html, additional_attributes: nil
      )
      allow(Messages::StatusUpdateService).to receive(:new).and_return(status_service)

      client.deliver(message: html_message)

      expect(a_request(:post, mail_send_url).with do |req|
        value = JSON.parse(req.body)['content'].first['value']
        value.include?('<!DOCTYPE html>') && value.exclude?('&lt;!DOCTYPE')
      end).to have_been_made
    end

    it 'appends the channel email_signature block when present' do
      signed_channel = instance_double(
        Channel::Sendgrid,
        api_key: 'SG.key-x',
        from_email: 'news@acme.com',
        from_name: 'Acme News',
        reply_to: nil,
        email_signature: '<p>Best, Acme</p>'
      )
      allow(Messages::StatusUpdateService).to receive(:new).and_return(status_service)

      described_class.new(signed_channel).deliver(message: message)

      expect(a_request(:post, mail_send_url).with do |req|
        value = JSON.parse(req.body)['content'].first['value']
        value.include?('<p>Best, Acme</p>') && value.include?('border-top')
      end).to have_been_made
    end

    # AC2 lock: any drift in template path, layout flag, or assigns list will
    # make the SendGrid value diverge from what ApplicationController.renderer
    # produces with the same inputs. Catches accidental rewording of the
    # render call that silently breaks parity with the SMTP path.
    it 'matches ApplicationController.renderer with the same template + assigns byte-for-byte (AC2)' do
      expected = ApplicationController.renderer.render(
        template: 'mailers/conversation_reply_mailer/email_reply',
        layout: false,
        assigns: {
          message: message,
          channel: channel,
          conversation: conversation,
          large_attachments: []
        }
      )
      allow(Messages::StatusUpdateService).to receive(:new).and_return(status_service)

      client.deliver(message: message)

      expect(a_request(:post, mail_send_url).with do |req|
        JSON.parse(req.body)['content'].first['value'] == expected
      end).to have_been_made
    end
  end

  describe '#deliver — provider rejects (4xx/5xx)' do
    it 'raises InvalidApiKeyError and marks failed on 401' do
      stub_request(:post, mail_send_url).to_return(status: 401, body: '{"errors":[]}')
      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'failed', 'SendGrid mail/send failed: 401').and_return(status_service)

      expect { client.deliver(message: message) }.to raise_error(Sendgrid::InvalidApiKeyError)
    end

    it 'raises ApiError and marks failed on 400, redacting the 4xx body in the log' do
      stub_request(:post, mail_send_url).to_return(status: 400, body: 'leaky-detail')
      allow(Messages::StatusUpdateService).to receive(:new).and_return(status_service)
      expect(Rails.logger).to receive(:error).with(/sg_response_status=400/).and_call_original
      expect(Rails.logger).not_to receive(:error).with(/leaky-detail/)

      expect { client.deliver(message: message) }.to raise_error(Sendgrid::ApiError)
    end

    it 'wraps transport failures as ServiceUnavailableError and marks the message failed' do
      stub_request(:post, mail_send_url).to_timeout
      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'failed', /SendGrid transport error/).and_return(status_service)

      expect { client.deliver(message: message) }.to raise_error(Sendgrid::ServiceUnavailableError)
    end
  end
end
