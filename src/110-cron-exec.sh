# ── Cron: exec wrapper (called by launchd) ────────────────────────────────────

cmd_cron_exec() {
  local cron_id="${1:-}"
  [[ -n "$cron_id" ]] || die "usage: cloard-board cron-exec <cron-id>"
  cron_job_exists "$cron_id" || die "cron job not found: ${cron_id}"

  local enabled
  enabled=$(cron_job_field "$cron_id" "enabled")
  [[ "$enabled" == "true" ]] || { echo "cron job ${cron_id} is disabled; skipping"; exit 0; }

  # Check for active runs (overlap prevention)
  local active_count
  active_count=$(jq -r --arg id "$cron_id" '[.cron_runs[] | select(.cron_job_id == $id and .status == "active")] | length' "$GLOBAL_STATE" 2>/dev/null) || active_count=0
  if [[ "$active_count" -gt 0 ]]; then
    echo "$(now_iso) SKIP: cron job ${cron_id} has an active run"
    exit 0
  fi

  # Cleanup stale runs
  _archive_stale_cron_runs

  # Generate session ID
  local session_id
  session_id=$(uuidgen | tr '[:upper:]' '[:lower:]')

  # Create run record
  local run_id
  run_id=$(_next_run_id)
  local epoch
  epoch=$(date +%s)
  local tmux_win="cron-${cron_id}-${epoch}"

  _lock_state || die "could not acquire lock"
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.cron.XXXXXX")
  jq --arg rid "$run_id" --arg cid "$cron_id" --arg sid "$session_id" \
    --arg win "$tmux_win" --arg now "$(now_iso)" '
    .cron_runs += [{
      run_id: $rid, cron_job_id: $cid, session_id: $sid,
      tmux_window: $win, started_at: $now, completed_at: null,
      exit_code: null, status: "active"
    }]
  ' "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state

  # Read job config
  local working_dir claude_cmd env_json
  working_dir=$(cron_job_field "$cron_id" "working_dir")
  claude_cmd=$(cron_job_field "$cron_id" "claude_command")
  env_json=$(jq -c --arg id "$cron_id" '.cron_jobs[] | select(.id == $id) | .env_vars // {}' "$GLOBAL_STATE")

  # Inject --session-id into the claude command
  claude_cmd="${claude_cmd} --session-id ${session_id}"

  # Build env export string
  local env_exports=""
  if [[ "$env_json" != "{}" && "$env_json" != "null" ]]; then
    while IFS=$'\x1e' read -r ekey eval; do
      [[ -n "$ekey" ]] || continue
      if [[ ! "$ekey" =~ ^[A-Za-z_][A-Za-z_0-9]*$ ]]; then
        warn "skipping invalid env var name: ${ekey}"
        continue
      fi
      env_exports="${env_exports}export ${ekey}=${(q)eval}; "
    done < <(echo "$env_json" | jq -r 'to_entries[] | [.key, .value] | join("\u001e")')
  fi

  # Ensure tmux session exists and create window
  ensure_tmux_session
  local safe_script=${(q)SCRIPT_PATH}
  local safe_working_dir=${(q)working_dir}
  tmux_create_window "$tmux_win" "zsh" "-c" \
    "${env_exports}cd ${safe_working_dir} && ${claude_cmd}; ${safe_script} _cron_complete ${run_id} \$?; exit"

  # Block until the run completes (poll every 5s for launchd lifecycle)
  while true; do
    local rstatus
    rstatus=$(cron_run_field "$run_id" "status") || break
    [[ "$rstatus" == "active" ]] || break
    sleep 5
  done
}

cmd__cron_complete() {
  local run_id="${1:-}" exit_code="${2:-0}"
  [[ -n "$run_id" ]] || return 0

  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.cron.XXXXXX")
  jq --arg rid "$run_id" --arg code "$exit_code" --arg now "$(now_iso)" '
    (.cron_runs[] | select(.run_id == $rid)) |=
      (.status = "needs_review" | .exit_code = ($code | tonumber) | .completed_at = $now)
  ' "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
}

