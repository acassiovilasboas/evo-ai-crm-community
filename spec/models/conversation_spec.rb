# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

RSpec.describe Conversation, type: :model do
  let(:user) { User.create!(email: 'owner@example.com', name: 'Owner') }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Test Contact', email: 'contact@example.com') }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(4)) }

  let(:default_pipeline) do
    Pipeline.create!(
      name: 'Default Pipeline',
      pipeline_type: Pipeline::VALID_TYPES.first,
      created_by: user,
      is_default: true
    )
  end
  let(:default_stage) { PipelineStage.create!(pipeline: default_pipeline, name: 'Stage 1', position: 1) }

  let(:vendas_pipeline) do
    Pipeline.create!(
      name: 'Vendas',
      pipeline_type: Pipeline::VALID_TYPES.first,
      created_by: user
    )
  end
  let(:vendas_stage) { PipelineStage.create!(pipeline: vendas_pipeline, name: 'Qualificado', position: 1) }

  def create_conversation(opts = {})
    Conversation.create!({
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox
    }.merge(opts))
  end

  describe '#assign_to_default_pipeline' do
    context 'quando o contato não está em nenhum pipeline' do
      before { default_stage } # garante que o pipeline padrão existe com stage

      it 'adiciona a conversa ao pipeline padrão' do
        conversation = create_conversation
        expect(PipelineItem.where(conversation: conversation, pipeline: default_pipeline)).to exist
      end

      it 'não falha se não existe pipeline padrão' do
        expect { create_conversation }.not_to raise_error
        expect(PipelineItem.count).to eq(0)
      end
    end

    context 'quando o contato tem lead histórico com completed_at preenchido' do
      before do
        default_stage
        vendas_stage
        # lead fechado — não deve ser considerado pelo .active scope
        PipelineItem.create!(
          pipeline: vendas_pipeline,
          pipeline_stage: vendas_stage,
          contact: contact,
          completed_at: 1.day.ago
        )
      end

      it 'ignora o lead fechado e cai no pipeline padrão' do
        conversation = create_conversation
        expect(PipelineItem.where(conversation: conversation, pipeline: default_pipeline)).to exist
        expect(PipelineItem.where(conversation: conversation, pipeline: vendas_pipeline)).not_to exist
      end
    end

    context 'quando o contato já está em um pipeline ativo (lead)' do
      before do
        default_stage
        vendas_stage
        PipelineItem.create!(
          pipeline: vendas_pipeline,
          pipeline_stage: vendas_stage,
          contact: contact
        )
      end

      it 'adiciona a conversa ao pipeline do contato, não ao padrão' do
        conversation = create_conversation
        expect(PipelineItem.where(conversation: conversation, pipeline: vendas_pipeline)).to exist
      end

      it 'não cria item no pipeline padrão' do
        conversation = create_conversation
        expect(PipelineItem.where(conversation: conversation, pipeline: default_pipeline)).not_to exist
      end

      it 'usa o stage onde o contato já está' do
        conversation = create_conversation
        item = PipelineItem.find_by(conversation: conversation, pipeline: vendas_pipeline)
        expect(item.pipeline_stage).to eq(vendas_stage)
      end
    end

    context 'quando o contato está em múltiplos pipelines' do
      let(:suporte_pipeline) do
        Pipeline.create!(
          name: 'Suporte',
          pipeline_type: Pipeline::VALID_TYPES.first,
          created_by: user
        )
      end
      let(:suporte_stage) { PipelineStage.create!(pipeline: suporte_pipeline, name: 'Aberto', position: 1) }

      before do
        default_stage
        vendas_stage
        suporte_stage
      end

      it 'usa o pipeline mais recente do contato' do
        # Controla tempo para garantir ordem determinística
        travel_to(2.days.ago) do
          PipelineItem.create!(
            pipeline: vendas_pipeline,
            pipeline_stage: vendas_stage,
            contact: contact
          )
        end
        travel_to(1.hour.ago) do
          PipelineItem.create!(
            pipeline: suporte_pipeline,
            pipeline_stage: suporte_stage,
            contact: contact
          )
        end

        conversation = create_conversation
        expect(PipelineItem.where(conversation: conversation, pipeline: suporte_pipeline)).to exist
        expect(PipelineItem.where(conversation: conversation, pipeline: vendas_pipeline)).not_to exist
      end
    end

    context 'quando não há contato associado' do
      before { default_stage }

      it 'usa o pipeline padrão como fallback' do
        contact2 = Contact.create!(name: 'No Contact', email: 'nocontact@example.com')
        ci2 = ContactInbox.create!(contact: contact2, inbox: inbox, source_id: SecureRandom.hex(4))
        conversation = Conversation.create!(inbox: inbox, contact: contact2, contact_inbox: ci2)
        expect(PipelineItem.where(conversation: conversation, pipeline: default_pipeline)).to exist
      end
    end

    context 'prevenção de duplicatas' do
      before { vendas_stage }

      it 'não cria PipelineItem duplicado se chamado duas vezes' do
        PipelineItem.create!(pipeline: vendas_pipeline, pipeline_stage: vendas_stage, contact: contact)
        conversation = create_conversation
        # simula segundo disparo do callback
        conversation.send(:assign_to_default_pipeline)
        expect(PipelineItem.where(conversation: conversation).count).to eq(1)
      end
    end

    context 'quando o contato tem apenas deals (itens com conversa vinculada)' do
      before do
        default_stage
        vendas_stage
        old_conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
        PipelineItem.where(conversation: old_conversation).destroy_all
        PipelineItem.create!(
          pipeline: vendas_pipeline,
          pipeline_stage: vendas_stage,
          conversation: old_conversation
        )
      end

      it 'cai no pipeline padrão pois não há lead ativo do contato' do
        new_ci = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(4))
        new_conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: new_ci)
        expect(PipelineItem.where(conversation: new_conversation, pipeline: default_pipeline)).to exist
      end
    end
  end

  describe '#resolve_target_pipeline' do
    before { vendas_stage }

    # Usa uma conversa persistida para evitar fragilidade do Conversation.new sem atributos obrigatórios
    let(:persisted_conversation) { create_conversation }

    it 'retorna pipeline e stage do lead ativo do contato' do
      PipelineItem.create!(pipeline: vendas_pipeline, pipeline_stage: vendas_stage, contact: contact)
      # Remove o item criado pelo callback para testar resolve_target_pipeline isolado
      PipelineItem.where(conversation: persisted_conversation).destroy_all

      pipeline, stage = persisted_conversation.send(:resolve_target_pipeline)
      expect(pipeline).to eq(vendas_pipeline)
      expect(stage).to eq(vendas_stage)
    end

    it 'retorna pipeline padrão quando contato não tem lead ativo' do
      default_stage
      PipelineItem.where(conversation: persisted_conversation).destroy_all

      pipeline, stage = persisted_conversation.send(:resolve_target_pipeline)
      expect(pipeline).to eq(default_pipeline)
      expect(stage).to be_nil
    end

    it 'retorna [nil, nil] quando não há pipeline padrão nem lead do contato' do
      PipelineItem.where(conversation: persisted_conversation).destroy_all

      pipeline, stage = persisted_conversation.send(:resolve_target_pipeline)
      expect(pipeline).to be_nil
      expect(stage).to be_nil
    end

    it 'retorna o lead-item do contato como 3º valor (para promoção)' do
      lead = PipelineItem.create!(pipeline: vendas_pipeline, pipeline_stage: vendas_stage, contact: contact)
      PipelineItem.where(conversation: persisted_conversation).destroy_all

      _pipeline, _stage, lead_item = persisted_conversation.send(:resolve_target_pipeline)
      expect(lead_item).to eq(lead)
    end
  end

  describe '#assign_to_default_pipeline fusão (lead-card promotion)' do
    before { vendas_stage }

    let(:persisted_conversation) { create_conversation }

    it 'PROMOVE o lead-card existente do contato em vez de criar um 2º card' do
      # Lead da compra: item por-contato (conversation_id nil) já no funil.
      lead = PipelineItem.create!(pipeline: vendas_pipeline, pipeline_stage: vendas_stage, contact: contact)
      PipelineItem.where(conversation: persisted_conversation).destroy_all

      expect do
        persisted_conversation.send(:assign_to_default_pipeline)
      end.not_to change(PipelineItem, :count) # promove, não cria

      expect(lead.reload.conversation_id).to eq(persisted_conversation.id)
      # Um único card ativo para o contato neste funil.
      expect(PipelineItem.active.where(contact: contact, pipeline: vendas_pipeline).count).to eq(1)
    end
  end
end
