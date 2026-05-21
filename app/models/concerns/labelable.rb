module Labelable
  extend ActiveSupport::Concern

  included do
    acts_as_taggable_on :labels
  end

  # F-2: label-change publishing moved to `after_update_commit` on Contact
  # (see `Contact#publish_label_changes`). Every write path that mutates
  # `label_list` and persists hits that callback, so update_labels/add_labels
  # no longer need to emit explicitly.
  def update_labels(labels = nil)
    update!(label_list: labels)
  end

  def add_labels(new_labels = nil)
    new_labels = Array(new_labels)
    combined_labels = labels + new_labels
    update!(label_list: combined_labels)
  end
end
