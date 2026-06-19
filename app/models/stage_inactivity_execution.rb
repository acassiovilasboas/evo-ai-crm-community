# == Schema Information
#
# Table name: stage_inactivity_executions
#
#  id                :uuid             not null, primary key
#  action            :string
#  action_config     :jsonb
#  base              :string
#  executed_at       :datetime         not null
#  message_sent      :text
#  rule_id           :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  pipeline_item_id  :uuid             not null
#  pipeline_stage_id :uuid             not null
#
# Indexes
#
#  index_stage_inactivity_executions_on_executed_at        (executed_at)
#  index_stage_inactivity_executions_on_pipeline_item_id   (pipeline_item_id)
#  index_stage_inactivity_on_item_and_rule                 (pipeline_item_id,rule_id) UNIQUE
#
# Tracks which inactivity rule already fired for a given pipeline_item, so the
# minute-by-minute scheduler does not re-send. The UNIQUE (pipeline_item_id,
# rule_id) index is the idempotency guard: the service reserves the row with an
# INSERT *before* sending, so a Sidekiq retry or two concurrent schedulers race
# on the INSERT — the loser hits RecordNotUnique and skips sending entirely.
class StageInactivityExecution < ApplicationRecord
  belongs_to :pipeline_item

  validates :rule_id, presence: true, uniqueness: { scope: :pipeline_item_id }
  validates :executed_at, presence: true

  scope :for_item, ->(pipeline_item_id) { where(pipeline_item_id: pipeline_item_id) }
  scope :ordered, -> { order(executed_at: :asc) }
  scope :recent, -> { order(executed_at: :desc) }

  # Whether a specific rule already fired for an item.
  def self.executed?(pipeline_item_id, rule_id)
    exists?(pipeline_item_id: pipeline_item_id, rule_id: rule_id)
  end

  # Reset executions for an item. When `base` is given, only that base is wiped
  # so resetting `no_customer_reply` (on incoming) does not clobber a pending
  # `stage_stagnation` execution, and vice versa.
  def self.reset_for_item(pipeline_item_id, base: nil)
    scope = for_item(pipeline_item_id)
    scope = scope.where(base: base) if base.present?
    scope.destroy_all
  end
end
