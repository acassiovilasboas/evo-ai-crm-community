require 'rails_helper'

RSpec.describe EvoFlow::SchemaValidator do
  describe '.validate!' do
    context 'when the event name is not in the schema (unknown / future)' do
      it 'passes through silently to preserve forward-compat' do
        expect do
          described_class.validate!('not.a.real.event', {})
        end.not_to raise_error
      end
    end

    context 'when the event is "custom"' do
      it 'accepts any free-form payload (AC4)' do
        expect do
          described_class.validate!('custom', { anything: 1, deeply: 'whatever' })
        end.not_to raise_error
      end

      it 'accepts an empty payload' do
        expect { described_class.validate!('custom', {}) }.not_to raise_error
      end
    end

    context 'AC3 — required-field enforcement (track event)' do
      it 'raises InvalidEventPayload when message.delivered is missing message_id' do
        expect do
          described_class.validate!(
            'message.delivered',
            channel_type: 'Channel::Whatsapp',
            conversation_id: 'conv-uuid',
            source: 'messaging'
          )
        end.to raise_error(EvoFlow::InvalidEventPayload) do |err|
          expect(err.event_name).to eq('message.delivered')
          expect(err.field).to eq(:message_id)
          expect(err.reason).to eq(:missing_required)
        end
      end

      it 'accepts message.delivered when all required fields are present' do
        expect do
          described_class.validate!(
            'message.delivered',
            message_id: 'msg-1',
            channel_type: 'Channel::Whatsapp',
            conversation_id: 'conv-1',
            source: 'messaging'
          )
        end.not_to raise_error
      end

      it 'tolerates string keys (Sidekiq round-trips through JSON)' do
        expect do
          described_class.validate!(
            'message.delivered',
            'message_id' => 'msg-1',
            'channel_type' => 'Channel::Whatsapp',
            'conversation_id' => 'conv-1',
            'source' => 'messaging'
          )
        end.not_to raise_error
      end
    end

    context 'AC3 — required-field enforcement (identify event)' do
      it 'raises InvalidEventPayload when contact.created traits lack id' do
        expect do
          described_class.validate!('contact.created', source: 'contact_created')
        end.to raise_error(EvoFlow::InvalidEventPayload) do |err|
          expect(err.field).to eq(:id)
        end
      end

      it 'accepts contact.created when id and source are present' do
        expect do
          described_class.validate!('contact.created', id: 'c-1', source: 'contact_created')
        end.not_to raise_error
      end
    end

    context 'type validation' do
      it 'rejects boolean where uuid is expected' do
        expect do
          described_class.validate!(
            'message.delivered',
            message_id: true,
            channel_type: 'Channel::Whatsapp',
            conversation_id: 'conv-1',
            source: 'messaging'
          )
        end.to raise_error(EvoFlow::InvalidEventPayload) do |err|
          expect(err.field).to eq(:message_id)
          expect(err.reason).to eq(:invalid_type)
        end
      end

      it 'accepts numeric uuid values from legacy contact_id paths' do
        expect do
          described_class.validate!(
            'message.created',
            message_id: 42,
            channel_type: 'Channel::Whatsapp',
            conversation_id: 'conv-1',
            source: 'messaging',
            message_type: 'incoming'
          )
        end.not_to raise_error
      end

      it 'accepts ISO-8601 strings for date fields' do
        expect do
          described_class.validate!(
            'contact.deleted',
            source: 'contact_deleted',
            deleted_at: '2026-05-25T12:00:00Z'
          )
        end.not_to raise_error
      end

      it 'accepts Time/ActiveSupport::TimeWithZone for date fields' do
        expect do
          described_class.validate!(
            'contact.deleted',
            source: 'contact_deleted',
            deleted_at: Time.zone.parse('2026-05-25T12:00:00Z')
          )
        end.not_to raise_error
      end

      it 'rejects an unparseable string for a date field' do
        expect do
          described_class.validate!(
            'contact.deleted',
            source: 'contact_deleted',
            deleted_at: 'not-a-date'
          )
        end.to raise_error(EvoFlow::InvalidEventPayload)
      end

      it 'rejects a string where number is expected' do
        expect do
          described_class.validate!(
            'conversation.created',
            conversation_id: 'conv-1',
            inbox_id: 'seven',
            source: 'conversation_management'
          )
        end.to raise_error(EvoFlow::InvalidEventPayload)
      end
    end

    context 'optional fields' do
      it 'allows the field to be absent' do
        expect do
          described_class.validate!(
            'conversation.created',
            conversation_id: 'conv-1', inbox_id: 7, source: 'conversation_management'
          )
        end.not_to raise_error
      end

      it 'still type-checks the field when present' do
        expect do
          described_class.validate!(
            'conversation.created',
            conversation_id: 'conv-1', inbox_id: 7, source: 'conversation_management',
            channel_type: 12345
          )
        end.to raise_error(EvoFlow::InvalidEventPayload)
      end
    end
  end
end
