# ── Cron helpers ──────────────────────────────────────────────────────────────
cron_job_exists() {
  local id="$1"
  [[ "$(jq -r --arg id "$id" '[.cron_jobs[] | select(.id == $id)] | length' "$GLOBAL_STATE")" -gt 0 ]]
}

cron_job_field() {
  local id="$1" field="$2"
  jq -r --arg id "$id" --arg f "$field" '.cron_jobs[] | select(.id == $id) | .[$f] // ""' "$GLOBAL_STATE" 2>/dev/null
}

update_cron_job_field() {
  local id="$1" field="$2" value="$3"
  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.cron.XXXXXX")
  jq --arg id "$id" --arg f "$field" --arg v "$value" \
    '(.cron_jobs[] | select(.id == $id))[$f] = $v' "$GLOBAL_STATE" > "$tmp" \
    && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
}

update_cron_job_field_raw() {
  local id="$1" field="$2" value="$3"
  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.cron.XXXXXX")
  jq --arg id "$id" --arg f "$field" --argjson v "$value" \
    '(.cron_jobs[] | select(.id == $id))[$f] = $v' "$GLOBAL_STATE" > "$tmp" \
    && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
}

cron_run_field() {
  local run_id="$1" field="$2"
  jq -r --arg id "$run_id" --arg f "$field" '.cron_runs[] | select(.run_id == $id) | .[$f] // ""' "$GLOBAL_STATE" 2>/dev/null
}

update_cron_run_field() {
  local run_id="$1" field="$2" value="$3"
  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.cron.XXXXXX")
  jq --arg id "$run_id" --arg f "$field" --arg v "$value" \
    '(.cron_runs[] | select(.run_id == $id))[$f] = $v' "$GLOBAL_STATE" > "$tmp" \
    && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
}

update_cron_run_field_raw() {
  local run_id="$1" field="$2" value="$3"
  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.cron.XXXXXX")
  jq --arg id "$run_id" --arg f "$field" --argjson v "$value" \
    '(.cron_runs[] | select(.run_id == $id))[$f] = $v' "$GLOBAL_STATE" > "$tmp" \
    && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
}

_next_cron_id() {
  _lock_state || return 1
  local num
  num=$(jq -r '.next_cron_id' "$GLOBAL_STATE")
  local new_id
  new_id=$(printf "cj-%03d" "$num")
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.cron.XXXXXX")
  jq '.next_cron_id += 1' "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
  echo "$new_id"
}

_next_run_id() {
  _lock_state || return 1
  local num
  num=$(jq -r '.next_run_id' "$GLOBAL_STATE")
  local new_id
  new_id=$(printf "cr-%03d" "$num")
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.cron.XXXXXX")
  jq '.next_run_id += 1' "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
  echo "$new_id"
}

