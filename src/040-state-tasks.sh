# ── JSON helpers (jq wrappers, global state) ──────────────────────────────────
read_task() {
  local id="$1"
  jq -r --arg id "$id" '.tasks[] | select(.id == $id)' "$GLOBAL_STATE"
}

task_exists() {
  local id="$1"
  [[ "$(jq -r --arg id "$id" '[.tasks[] | select(.id == $id)] | length' "$GLOBAL_STATE")" -gt 0 ]]
}

task_status() {
  local id="$1"
  jq -r --arg id "$id" '.tasks[] | select(.id == $id) | .status' "$GLOBAL_STATE"
}

task_field() {
  local id="$1" field="$2"
  jq -r --arg id "$id" --arg f "$field" '.tasks[] | select(.id == $id) | .[$f] // ""' "$GLOBAL_STATE" 2>/dev/null
}

update_task_field() {
  local id="$1" field="$2" value="$3"
  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.tasks.XXXXXX")
  jq --arg id "$id" --arg f "$field" --arg v "$value" \
    '(.tasks[] | select(.id == $id))[$f] = $v' "$GLOBAL_STATE" > "$tmp" \
    && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
}

update_task_field_raw() {
  # For non-string values (null, numbers)
  local id="$1" field="$2" value="$3"
  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.tasks.XXXXXX")
  jq --arg id "$id" --arg f "$field" --argjson v "$value" \
    '(.tasks[] | select(.id == $id))[$f] = $v' "$GLOBAL_STATE" > "$tmp" \
    && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
}

# Swap two tasks' positions in the state JSON array (for reordering within a column)
_swap_tasks_in_state() {
  local id_a="$1" id_b="$2"
  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.tasks.XXXXXX")
  jq --arg a "$id_a" --arg b "$id_b" '
    (.tasks | to_entries) as $entries |
    ($entries | map(select(.value.id == $a)) | .[0].key) as $idx_a |
    ($entries | map(select(.value.id == $b)) | .[0].key) as $idx_b |
    if $idx_a != null and $idx_b != null then
      .tasks[$idx_a] = $entries[$idx_b].value |
      .tasks[$idx_b] = $entries[$idx_a].value
    else . end
  ' "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
}

