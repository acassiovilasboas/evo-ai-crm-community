module EvoFlow
  # Validates an event payload (properties for track, traits for identify)
  # against the schema declared in EvoFlow::EVENT_SCHEMA.
  #
  # Called from EvoFlow::PayloadBuilder.build_track / build_identify after
  # validate_event_name!. Raises EvoFlow::InvalidEventPayload, which the
  # worker treats the same as InvalidEventName: log + drop + broadcast
  # :evo_flow_publish_dropped, no retry.
  class SchemaValidator
    UUID_REGEX = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.freeze

    def self.validate!(event_name, payload)
      schema = EvoFlow::EventSchema.fetch(event_name)
      return if schema.nil?

      normalized = stringify_keys(payload)

      schema[:required].each do |field, type|
        value = normalized[field.to_s]
        if value.nil?
          raise EvoFlow::InvalidEventPayload.new(
            event_name: event_name, field: field, reason: :missing_required
          )
        end
        assert_type!(event_name, field, type, value)
      end

      schema[:optional].each do |field, type|
        value = normalized[field.to_s]
        next if value.nil?

        assert_type!(event_name, field, type, value)
      end
    end

    def self.stringify_keys(hash)
      return {} if hash.nil?

      hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end
    private_class_method :stringify_keys

    def self.assert_type!(event_name, field, type, value)
      return if matches_type?(type, value)

      raise EvoFlow::InvalidEventPayload.new(
        event_name: event_name, field: field, reason: :invalid_type,
        details: "expected #{type}, got #{value.class}"
      )
    end
    private_class_method :assert_type!

    def self.matches_type?(type, value)
      case type
      when :string then value.is_a?(String)
      when :number then value.is_a?(Numeric)
      when :boolean then [true, false].include?(value)
      when :object then value.is_a?(Hash)
      when :uuid then matches_uuid?(value)
      when :date then matches_date?(value)
      else false
      end
    end
    private_class_method :matches_type?

    # Listeners pass UUIDs as strings AND raw integers (legacy contact_id paths).
    # Accept both — server-side downstream coerces to string.
    def self.matches_uuid?(value)
      return true if value.is_a?(String) && UUID_REGEX.match?(value)
      return true if value.is_a?(String) && value.length.positive?
      return true if value.is_a?(Integer) || value.is_a?(Numeric)

      false
    end
    private_class_method :matches_uuid?

    def self.matches_date?(value)
      return true if value.respond_to?(:iso8601)
      return false unless value.is_a?(String)

      Time.iso8601(value)
      true
    rescue ArgumentError
      false
    end
    private_class_method :matches_date?
  end
end
