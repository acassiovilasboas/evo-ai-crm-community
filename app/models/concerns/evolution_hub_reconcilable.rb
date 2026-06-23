# frozen_string_literal: true

# Auto-heal LAZY de canais EvoHub (WhatsApp/FB/IG): quando um canal é TOCADO (envio/publicação)
# e está DEGRADADO — status != 'active' OU sem channel_token — reconcilia on-the-fly consultando
# o Hub (GET /channels/:id), sem exigir reconexão manual. Conserta canais que escaparam do webhook
# (ex.: channel_connected perdido, IG preso em 'pending', FB sem token).
#
# DESIGN (decisões já firmadas):
#   • LAZY-on-use, NÃO job: roda no caminho Ruby de uso do canal (request com tenant) → contexto/RLS
#     corretos por construção. Um job sem request daria no-op silencioso de RLS.
#   • Guarda de COOLDOWN (Redis): um canal permanentemente quebrado não martela o Hub a cada uso.
#   • Reusa EvolutionHub::ChannelReconciler.heal_from_hub (fonte única — sem cópia de lógica).
#   • Best-effort: nunca levanta no caminho de uso (heal é melhoria, não bloqueio).
module EvolutionHubReconcilable
  extend ActiveSupport::Concern

  HEAL_COOLDOWN_SECONDS = 300 # 5 min — evita martelar o Hub num canal cronicamente quebrado

  # Reconcilia do Hub SE o canal estiver degradado e fora do cooldown. Retorna true se tentou heal.
  # Chamar ANTES de usar o canal (publicar/enviar). Best-effort.
  def heal_from_hub_if_stale!
    return false unless evolution_hub_managed?
    return false unless hub_channel_degraded?
    return false unless heal_cooldown_elapsed?

    mark_heal_attempt!
    healed = ::EvolutionHub::ChannelReconciler.heal_from_hub(self)
    Rails.logger.info("EvolutionHubReconcilable: auto-heal #{self.class.name}##{id} → #{healed ? 'reconciliado' : 'sem mudança'}")
    healed
  rescue StandardError => e
    Rails.logger.warn("EvolutionHubReconcilable: auto-heal falhou #{self.class.name}##{id} (#{e.class}: #{e.message})")
    false
  end

  private

  # Só canais gerenciados pelo Hub (têm hub channel_id) entram no auto-heal.
  def evolution_hub_managed?
    ::EvolutionHub::ChannelReconciler.hub_channel_id_of(self).present?
  end

  # Degradado = não-ativo OU sem channel_token (a credencial que o proxy do Hub exige).
  def hub_channel_degraded?
    block = is_a?(::Channel::Whatsapp) ? (provider_config || {})['evolution_hub'] : evolution_hub_meta
    block ||= {}
    block['status'] != 'active' || block['channel_token'].blank?
  end

  def heal_cooldown_elapsed?
    ::Redis::Alfred.get(heal_cooldown_key).blank?
  rescue StandardError
    true # se o Redis falhar, não bloqueia o heal (best-effort)
  end

  def mark_heal_attempt!
    # Redis::Alfred.setex(key, value, expiry) — value=timestamp, expiry=cooldown.
    ::Redis::Alfred.setex(heal_cooldown_key, Time.current.to_i, HEAL_COOLDOWN_SECONDS)
  rescue StandardError
    nil # cooldown é otimização; falha no Redis não impede o heal
  end

  def heal_cooldown_key
    "evohub:heal_cooldown:#{self.class.name}:#{id}"
  end
end
