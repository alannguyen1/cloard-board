# ── Global state management ───────────────────────────────────────────────────
ensure_global_state() {
  mkdir -p "$GLOBAL_DIR"

  if [[ ! -f "$GLOBAL_STATE" ]]; then
    jq -n '{version: 4, next_task_id: 1, next_cron_id: 1, next_run_id: 1, repos: [], tasks: [], cron_jobs: [], cron_runs: []}' > "$GLOBAL_STATE"
  else
    # Check for schema migrations
    local _ver
    _ver=$(jq -r '.version // 0' "$GLOBAL_STATE" 2>/dev/null) || _ver=0
    if [[ "$_ver" == "2" ]]; then
      _migrate_v2_to_v3
      _ver=3
    fi
    if [[ "$_ver" == "3" ]]; then
      _migrate_v3_to_v4
    fi
  fi

  # Install hooks if missing or outdated
  local _hook_ver=""
  if [[ -f "$HOOKS_DIR/on-prompt.sh" ]]; then
    _hook_ver=$(grep -o 'hook-version:[0-9]*' "$HOOKS_DIR/on-prompt.sh" 2>/dev/null | cut -d: -f2) || true
  fi
  if [[ ! -f "$HOOKS_DIR/on-stop.sh" || ! -f "$HOOKS_DIR/on-prompt.sh" || "$_hook_ver" != "$HOOK_VERSION" ]]; then
    _install_hook_scripts
    _register_global_hooks
  fi
}

_install_hook_scripts() {
  mkdir -p "$HOOKS_DIR"

  cat > "$HOOKS_DIR/on-stop.sh" <<HOOK
#!/usr/bin/env bash
# cloard-board hook: set task status to "waiting" when Claude stops
# hook-version:${HOOK_VERSION}
[[ -n "\${CLOARD_TASK_ID:-}" ]] || exit 0
cloard-board signal "\$CLOARD_TASK_ID" waiting &>/dev/null &
HOOK
  chmod +x "$HOOKS_DIR/on-stop.sh"

  cat > "$HOOKS_DIR/on-prompt.sh" <<HOOK
#!/usr/bin/env bash
# cloard-board hook: set task status to "working" when user submits a prompt
# hook-version:${HOOK_VERSION}
[[ -n "\${CLOARD_TASK_ID:-}" ]] || exit 0
cloard-board signal "\$CLOARD_TASK_ID" working &>/dev/null &
cloard-board _capture-session-uid "\$CLOARD_TASK_ID" &>/dev/null &
HOOK
  chmod +x "$HOOKS_DIR/on-prompt.sh"
}

_register_global_hooks() {
  local settings_dir="$HOME/.claude"
  local settings_file="$settings_dir/settings.json"
  mkdir -p "$settings_dir"

  local new_hooks
  new_hooks=$(jq -n --arg stop "$HOOKS_DIR/on-stop.sh" --arg prompt "$HOOKS_DIR/on-prompt.sh" '{
    "Stop": [{"hooks": [{"type": "command", "command": $stop}]}],
    "PostToolUse": [
      {"matcher": "AskUserQuestion", "hooks": [{"type": "command", "command": $stop}]},
      {"matcher": "ExitPlanMode", "hooks": [{"type": "command", "command": $stop}]}
    ],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": $prompt}]}]
  }')

  if [[ -f "$settings_file" ]]; then
    local tmp_settings
    tmp_settings=$(mktemp "${GLOBAL_DIR}/.settings.XXXXXX")
    # Merge hooks: remove any existing cloard-board entries, then append ours
    jq --argjson new_hooks "$new_hooks" '
      .hooks = ((.hooks // {}) |
        reduce ($new_hooks | to_entries[]) as $entry (.;
          .[$entry.key] = (
            [(.[$entry.key] // [])[] |
              select(.hooks | all(.command | test("cloard-board") | not))
            ] + $entry.value
          )
        )
      )
    ' "$settings_file" > "$tmp_settings" \
      && mv "$tmp_settings" "$settings_file"
  else
    jq -n --argjson hooks "$new_hooks" '{hooks: $hooks}' > "$settings_file"
  fi
}

_migrate_v2_to_v3() {
  info "migrating state schema v2 -> v3 (adding cron support)..."
  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.migrate.XXXXXX")
  jq '.version = 3
    | .next_cron_id = (.next_cron_id // 1)
    | .next_run_id = (.next_run_id // 1)
    | .cron_jobs = (.cron_jobs // [])
    | .cron_runs = (.cron_runs // [])' "$GLOBAL_STATE" > "$tmp" \
    && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
  ok "state schema migrated to v3"
}

_migrate_v3_to_v4() {
  info "migrating state schema v3 -> v4 (adding session history)..."
  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.migrate.XXXXXX")
  jq '.version = 4
    | .tasks = [.tasks[] |
        if .session_uid and .session_uid != null and .session_uid != "" then
          .session_history = [.session_uid]
        else
          .session_history = []
        end
      ]' "$GLOBAL_STATE" > "$tmp" \
    && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
  ok "state schema migrated to v4"
}

# Auto-migrate old per-repo state on first run from that directory
check_and_migrate() {
  local local_state=".cloard-board/tasks.json"
  [[ -f "$local_state" ]] || return 0

  # Check if it's v1 format
  local version
  version=$(jq -r '.version // 0' "$local_state" 2>/dev/null) || return 0
  [[ "$version" == "1" ]] || return 0

  # Check if this repo is already registered
  local cwd_canonical
  cwd_canonical=$(pwd -P)
  local already_registered
  already_registered=$(jq -r --arg p "$cwd_canonical" '[.repos[] | select(.path == $p)] | length' "$GLOBAL_STATE")
  [[ "$already_registered" -eq 0 ]] || return 0

  # Count tasks
  local task_count
  task_count=$(jq '.tasks | length' "$local_state")

  # Skip migration prompt in non-interactive contexts
  if [[ ! -t 0 ]]; then
    return 0
  fi

  printf "${C_CYAN}Found local cloard-board state with ${task_count} tasks. Migrate to global dashboard? [Y/n] ${C_RESET}"
  local answer
  read -r answer
  [[ "$answer" =~ ^[nN]$ ]] && return 0

  # Register this repo
  local repo_name
  repo_name=$(basename "$cwd_canonical")
  repo_name=$(_do_repo_add "$cwd_canonical" "$repo_name") || return 1

  # Import tasks with new IDs
  local old_tasks
  old_tasks=$(jq -r '.tasks[] | [
    .id, .title, .status,
    (.worktree_mode // "worktree"),
    (.claude_status // ""),
    (.pr_url // ""),
    (.branch // ""),
    (.worktree // ""),
    (.started_at // ""),
    (.completed_at // "")
  ] | join("\u001e")' "$local_state")

  while IFS=$'\x1e' read -r old_id old_title old_status old_wm old_cs old_pr old_branch old_wt old_started old_completed; do
    [[ -n "$old_id" ]] || continue
    local new_id
    new_id=$(_next_task_id_unlocked)
    local tmp
    tmp=$(mktemp "${GLOBAL_DIR}/.tasks.XXXXXX")
    local now
    now=$(now_iso)
    jq --arg id "$new_id" --arg title "$old_title" --arg status "$old_status" \
       --arg wm "$old_wm" --arg repo "$repo_name" --arg cs "$old_cs" \
       --arg pr "$old_pr" --arg branch "$old_branch" --arg wt "$old_wt" \
       --arg old_id "$old_id" --arg started "$old_started" --arg completed "$old_completed" \
       --arg now "$now" \
      '.tasks += [{
        id: $id,
        title: $title,
        repo: $repo,
        status: $status,
        worktree_mode: $wm,
        worktree: (if $wt == "" then null else $wt end),
        branch: (if $branch == "" then null else $branch end),
        claude_status: (if $cs == "" then null else $cs end),
        pr_number: null,
        pr_url: (if $pr == "" then null else $pr end),
        created_at: $now,
        started_at: (if $started == "" then null else $started end),
        completed_at: (if $completed == "" then null else $completed end),
        legacy_id: $old_id
      }]' "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
  done <<< "$old_tasks"

  # Rename old state directory (backup)
  mv ".cloard-board" ".cloard-board.migrated"

  # Clean up per-repo hook entries from local .claude/settings.json
  if [[ -f ".claude/settings.json" ]]; then
    local tmp_s
    tmp_s=$(mktemp)
    jq '
      if .hooks then
        .hooks |= with_entries(
          .value = [.value[] | select(.hooks | all(.command | test("cloard-board") | not))]
        )
      else . end
    ' ".claude/settings.json" > "$tmp_s" && mv "$tmp_s" ".claude/settings.json"
  fi

  ok "migrated ${task_count} tasks from local state; old state backed up to .cloard-board.migrated/"
}

