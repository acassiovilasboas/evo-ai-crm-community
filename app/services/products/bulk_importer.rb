# frozen_string_literal: true

# Bulk-imports products in a single ACID transaction (EVO-1555 S1).
#
# Public entry point: `Products::BulkImporter.new(items).call`.
# Raises Products::BulkImporter::BulkImportError carrying a positional
# errors payload when any item fails — the whole batch is rolled back.
module Products
  class BulkImporter
    MAX_ITEMS = 500
    SCALAR_ATTRS = %i[
      name slug kind description sku
      default_price currency purchase_url
      status stock_quantity
    ].freeze

    class BulkImportError < StandardError
      attr_reader :errors_payload

      def initialize(errors_payload)
        @errors_payload = errors_payload
        super('Bulk import failed')
      end
    end

    def initialize(items)
      @items = items
    end

    def call
      pre_errors = pre_validate_items
      raise BulkImportError, pre_errors if pre_errors.any?

      created = []

      ActiveRecord::Base.transaction do
        errors_acc = []
        @items.each_with_index { |raw_item, index| import_one(raw_item, index, created, errors_acc) }
        raise BulkImportError, errors_acc if errors_acc.any?
      end

      created
    end

    private

    # First pass: collects all type errors AND intra-batch SKU conflicts together,
    # so the client gets the full picture in a single 422 instead of finding the
    # next error only after fixing the previous one.
    def pre_validate_items
      errors = []
      seen_skus = {}

      @items.each_with_index do |raw_item, index|
        unless hash_like?(raw_item)
          errors << { index: index, sku: nil, errors: { base: ['item must be a JSON object'] } }
          next
        end

        sku = raw_item[:sku]
        next if sku.blank?

        if seen_skus.key?(sku)
          errors << { index: index, sku: sku, errors: { sku: ['duplicated within batch'] } }
        else
          seen_skus[sku] = index
        end
      end

      errors
    end

    def import_one(raw_item, index, created, errors_acc)
      scalar_attrs, labels = item_params(raw_item)
      product = Product.new(scalar_attrs)

      unless product.save
        errors_acc << { index: index, sku: scalar_attrs[:sku], errors: product.errors.as_json }
        return
      end

      product.update_labels(labels) if labels.present?
      created << product
    end

    def item_params(raw_item)
      params_obj = raw_item.is_a?(ActionController::Parameters) ? raw_item : ActionController::Parameters.new(raw_item.to_h)
      permitted = params_obj.permit(*SCALAR_ATTRS, metadata: {}).to_h.symbolize_keys

      # Normalise blank SKU to nil so the partial unique index (WHERE sku IS NOT NULL)
      # treats "no SKU" rows as truly absent — otherwise two items with sku: "" raise
      # PG::UniqueViolation outside the AR validation layer.
      permitted[:sku] = nil if permitted[:sku].blank?

      labels_raw = params_obj[:labels]
      labels = labels_raw.present? ? Array(labels_raw).map(&:to_s) : nil

      [permitted, labels]
    end

    def hash_like?(item)
      item.is_a?(Hash) || item.is_a?(ActionController::Parameters)
    end
  end
end
