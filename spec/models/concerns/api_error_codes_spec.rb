# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApiErrorCodes do
  # Path to the module source, used to parse the #status_for case/when so the
  # guard stays in sync automatically as new codes are mapped there.
  source_path = Rails.root.join('app/models/concerns/api_error_codes.rb')
  source = File.read(source_path)

  # Extract the body of #status_for (between the method definition and the
  # final `else`) and collect every ALL_CAPS token referenced in its `when`
  # clauses. Each of those tokens must resolve to a defined constant, otherwise
  # calling #status_for (or any controller passing that code) raises NameError
  # and turns a structured 4xx into an opaque 500 (EVO-1923 / EVO-1899 class).
  status_for_body = source[/def self\.status_for.*?\n(.*?)\n\s*else/m, 1].to_s
  referenced_codes = status_for_body.scan(/\b([A-Z][A-Z0-9_]+)\b/).flatten.uniq

  describe 'constant definitions referenced by #status_for' do
    it 'parses at least one code from the case/when (sanity)' do
      expect(referenced_codes).not_to be_empty
    end

    referenced_codes.each do |code_name|
      it "defines #{code_name} so referencing it never raises NameError" do
        expect(described_class.const_defined?(code_name, false))
          .to be(true), "ApiErrorCodes::#{code_name} is referenced in #status_for but not defined"
        expect(described_class.const_get(code_name)).to eq(code_name)
      end
    end
  end

  describe 'constants used at real call-sites (EVO-1923)' do
    # The 11 codes flagged as used in controllers/services but previously
    # undefined. Kept as an explicit list as a redundant, intent-documenting
    # guard independent of the case/when parsing above.
    used_at_call_sites = %w[
      CONTACT_NOT_FOUND
      CONVERSATION_NOT_FOUND
      TEAM_NOT_FOUND
      LABEL_NOT_FOUND
      MACRO_NOT_FOUND
      NOTIFICATION_NOT_FOUND
      CUSTOM_FILTER_NOT_FOUND
      CUSTOM_ATTRIBUTE_NOT_FOUND
      AUTOMATION_RULE_NOT_FOUND
      CANNOT_DELETE_RESOURCE
      OPERATION_FAILED
    ]

    used_at_call_sites.each do |code_name|
      it "defines #{code_name}" do
        expect(described_class.const_defined?(code_name, false)).to be(true)
        expect(described_class.const_get(code_name)).to eq(code_name)
      end
    end
  end

  describe '.status_for' do
    it 'maps every *_NOT_FOUND code in the 404 clause to :not_found' do
      not_found_codes = referenced_codes.select { |c| c.end_with?('_NOT_FOUND') }
      not_found_codes.each do |code_name|
        value = described_class.const_get(code_name)
        expect(described_class.status_for(value)).to eq(:not_found)
      end
    end

    it 'returns :internal_server_error for unknown codes' do
      expect(described_class.status_for('SOMETHING_UNKNOWN')).to eq(:internal_server_error)
    end

    it 'does not raise NameError when invoked with any referenced code' do
      expect { described_class.status_for(ApiErrorCodes::CONTACT_NOT_FOUND) }.not_to raise_error
    end
  end
end
