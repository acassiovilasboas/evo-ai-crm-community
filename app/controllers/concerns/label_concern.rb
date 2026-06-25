module LabelConcern
  UUID_REGEX = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  def create
    model.update_labels(resolve_label_titles(permitted_params[:labels]))
    @labels = model.label_list
    render json: { payload: @labels }
  end

  def index
    @labels = model.label_list
    render json: { payload: @labels }
  end

  private

  # Clients historically sent label identifiers as UUIDs (matching the Label
  # PK exposed by the `/labels` endpoint). `acts_as_taggable_on :labels`
  # stores whatever string it receives as `tags.name`, so passing UUIDs caused
  # two downstream problems: activity messages rendered UUIDs instead of
  # human-readable titles, and `filter_service#tag_filter_query` (which
  # compares against `tags.name`) could not match on the user-configured
  # title. Translate UUID-shaped inputs to titles here; leave other strings
  # untouched for back-compat with any caller that already sends titles.
  #
  # EVO-1897 (D8): a UUID that does NOT resolve to a `Label` row (e.g. a
  # journey/evo-flow caller carrying an id that is absent from the local
  # `labels` table) must NOT be silently dropped. Doing so made
  # `update_labels([])` wipe the list and reply `200` with no tagging
  # persisted — a false-success for add-label/remove-label nodes. Preserve
  # the original token when it cannot be resolved so the caller's intent is
  # always reflected as a real tagging.
  def resolve_label_titles(labels)
    return labels if labels.blank?

    uuids, non_uuids = Array(labels).map(&:to_s).partition { |value| UUID_REGEX.match?(value) }
    return non_uuids if uuids.empty?

    titles_by_id = Label.where(id: uuids).pluck(:id, :title).to_h
    resolved = uuids.map { |id| titles_by_id[id] || id }
    (non_uuids + resolved).uniq
  end
end
