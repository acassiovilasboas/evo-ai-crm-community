module EvoFlow
  # Ruby mirror of evo-flow/src/modules/events/manifest/event-catalog.ts.
  # Locked in lockstep by scripts/check-event-manifest-sync.sh (CI gate).
  # When adding/changing an event schema, edit BOTH this file and the TS
  # catalog — the CI script fails the build on drift.
  #
  # Categories: contact | conversation | message | campaign | custom.
  # FieldType (TS): string | number | boolean | date | uuid | object
  # In Ruby, the validator (EvoFlow::SchemaValidator) maps each type to a
  # concrete predicate — see schema_validator.rb.
  #
  # Wrapped in a class (rather than a top-level EVENT_SCHEMA constant) so
  # Zeitwerk's expected_definition check passes for this file's path.
  class EventSchema
    def self.fetch(event_name)
      DEFINITIONS[event_name]
    end

    DEFINITIONS = {
    'contact.created' => {
      category: :contact,
      required: { id: :uuid, source: :string },
      optional: {
        name: :string, email: :string, phone_number: :string, identifier: :string,
        middle_name: :string, last_name: :string, location: :string, country_code: :string,
        contact_type: :string, blocked: :boolean, created_at: :date, updated_at: :date,
        customAttributes: :object, additionalAttributes: :object, created_via: :string
      },
      allow_extra_properties: true
    },
    'contact.updated' => {
      category: :contact,
      required: { id: :uuid, source: :string },
      optional: {
        name: :string, email: :string, phone_number: :string, identifier: :string,
        middle_name: :string, last_name: :string, location: :string, country_code: :string,
        contact_type: :string, blocked: :boolean, created_at: :date, updated_at: :date,
        customAttributes: :object, additionalAttributes: :object, created_via: :string,
        changes: :object
      },
      allow_extra_properties: true
    },
    'contact.deleted' => {
      category: :contact,
      required: { source: :string, deleted_at: :date },
      optional: { reason: :string },
      allow_extra_properties: true
    },
    'contact.label.added' => {
      category: :contact,
      required: { labelName: :string, labelId: :string, source: :string },
      optional: {},
      allow_extra_properties: true
    },
    'contact.label.removed' => {
      category: :contact,
      required: { labelName: :string, labelId: :string, source: :string },
      optional: {},
      allow_extra_properties: true
    },
    'contact.custom_attribute.changed' => {
      category: :contact,
      required: { attributeName: :string, source: :string },
      optional: { attributeValue: :string, changeType: :string, oldValue: :string },
      allow_extra_properties: true
    },
    'conversation.created' => {
      category: :conversation,
      required: { conversation_id: :uuid, inbox_id: :number, source: :string },
      optional: { inbox_name: :string, channel_type: :string },
      allow_extra_properties: true
    },
    'conversation.resolved' => {
      category: :conversation,
      required: { conversation_id: :uuid, inbox_id: :number, source: :string },
      optional: {
        inbox_name: :string, channel_type: :string,
        resolved_by_id: :string, resolved_by_type: :string, resolution_time_seconds: :number
      },
      allow_extra_properties: true
    },
    'message.created' => {
      category: :message,
      required: {
        message_id: :uuid, channel_type: :string, conversation_id: :uuid,
        source: :string, message_type: :string
      },
      optional: { content_type: :string, content: :string },
      allow_extra_properties: true
    },
    'message.delivered' => {
      category: :message,
      required: {
        message_id: :uuid, channel_type: :string, conversation_id: :uuid, source: :string
      },
      optional: {
        message_type: :string, content_type: :string, content: :string,
        previous_status: :string, status: :string, external_error: :string
      },
      allow_extra_properties: true
    },
    'message.read' => {
      category: :message,
      required: {
        message_id: :uuid, channel_type: :string, conversation_id: :uuid, source: :string
      },
      optional: {
        message_type: :string, content_type: :string, content: :string,
        previous_status: :string, status: :string, external_error: :string
      },
      allow_extra_properties: true
    },
    'message.failed' => {
      category: :message,
      required: {
        message_id: :uuid, channel_type: :string, conversation_id: :uuid, source: :string
      },
      optional: {
        message_type: :string, content_type: :string, content: :string,
        previous_status: :string, status: :string, external_error: :string
      },
      allow_extra_properties: true
    },
    'campaign.triggered' => {
      category: :campaign,
      required: { pipeline_item_id: :uuid, pipeline_id: :uuid, source: :string },
      optional: {
        conversation_id: :uuid, contact_id: :uuid, is_lead: :boolean,
        pipeline_name: :string, pipeline_stage_id: :uuid, pipeline_stage_name: :string,
        assigned_by_id: :number, custom_fields: :object
      },
      allow_extra_properties: true
    },
    'campaign.message.sent' => {
      category: :campaign,
      required: { campaign_id: :uuid, message_id: :uuid, source: :string },
      optional: { contact_id: :uuid, channel_type: :string, template_id: :uuid },
      allow_extra_properties: true
    },
    'campaign.message.opened' => {
      category: :campaign,
      required: { campaign_id: :uuid, message_id: :uuid, source: :string },
      optional: { contact_id: :uuid, opened_at: :date },
      allow_extra_properties: true
    },
    'campaign.message.clicked' => {
      category: :campaign,
      required: { campaign_id: :uuid, message_id: :uuid, source: :string },
      optional: { contact_id: :uuid, url: :string, clicked_at: :date },
      allow_extra_properties: true
    },
    'custom' => {
      category: :custom,
      required: {},
      optional: {},
      allow_extra_properties: true
    }
    }.each_value(&:freeze).freeze

    # Sanity check at load time: every EVENT_NAME must have a schema entry.
    # Mirrors the TS-side assertCatalogCoversAllNames().
    missing = EvoFlow::EVENT_NAMES.reject { |name| DEFINITIONS.key?(name) }
    raise "EvoFlow::EventSchema::DEFINITIONS is missing entries: #{missing.join(', ')}" if missing.any?
  end
end
