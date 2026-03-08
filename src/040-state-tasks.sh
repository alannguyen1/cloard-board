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

# Push a session UID onto a task's history stack.
# Prepends new_uid, deduplicates, caps at MAX_SESSION_HISTORY, syncs session_uid.
push_session_history() {
  local id="$1" new_uid="$2"
  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.tasks.XXXXXX")
  jq --arg id "$id" --arg uid "$new_uid" --argjson max "$MAX_SESSION_HISTORY" '
    (.tasks[] | select(.id == $id)) |= (
      ([$uid] + [(.session_history // [])[] | select(. != $uid)])[:$max] as $new |
      .session_history = $new |
      .session_uid = $new[0]
    )
  ' "$GLOBAL_STATE" > "$tmp" \
    && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
}

# Return newline-delimited session UIDs (newest first) for a task.
# Falls back to session_uid if session_history is absent (pre-migration).
get_session_history() {
  local id="$1"
  local hist
  hist=$(jq -r --arg id "$id" '
    .tasks[] | select(.id == $id) |
    if (.session_history // []) | length > 0 then
      .session_history[]
    elif .session_uid != null and .session_uid != "" then
      .session_uid
    else
      empty
    end
  ' "$GLOBAL_STATE" 2>/dev/null)
  [[ -n "$hist" ]] && echo "$hist"
  return 0
}

# Promote a history entry to position 0 and update session_uid to match.
set_session_uid_from_history() {
  local id="$1" uid="$2"
  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.tasks.XXXXXX")
  jq --arg id "$id" --arg uid "$uid" '
    (.tasks[] | select(.id == $id)) |= (
      (.session_history // []) as $old |
      if ($old | index($uid)) != null then
        ([$uid] + [$old[] | select(. != $uid)]) as $new |
        .session_history = $new |
        .session_uid = $uid
      else . end
    )
  ' "$GLOBAL_STATE" > "$tmp" \
    && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
}

