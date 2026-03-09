# ── Commands ───────────────────────────────────────────────────────────────────

# Check if a Claude session exists on disk.
# Sessions stored at ~/Library/Application Support/Claude/claude-code-sessions/*/UUID/
_claude_session_exists() {
  local uid="$1"
  local sessions_root="${HOME}/Library/Application Support/Claude/claude-code-sessions"
  [[ -d "$sessions_root" ]] || return 1
  local matches=("${sessions_root}"/*/"${uid}"(N))
  [[ ${#matches[@]} -gt 0 ]] && [[ -d "${matches[0]}" ]]
}

# Build the right Claude resume command for a task.
# Uses --resume <session_uid> if the session exists on disk, falls back to --continue.
_build_claude_resume_cmd() {
  local id="$1"
  local session_uid
  session_uid=$(task_field "$id" "session_uid")
  if [[ -n "$session_uid" && "$session_uid" != "null" ]] && _claude_session_exists "$session_uid"; then
    echo "claude --resume ${session_uid} --dangerously-skip-permissions"
  else
    echo "claude --continue --dangerously-skip-permissions"
  fi
}

# Capture session_uid for a task by scanning all session files in the project dir.
# Compares each UID against the task's existing history, pushing any new ones.
# Called from the on-prompt hook on each prompt submission.
cmd__capture_session_uid() {
  [[ -f "$GLOBAL_STATE" ]] || return 0
  local id="${1:-}"
  [[ -n "$id" ]] || return 0
  task_exists "$id" || return 0

  local repo_name
  repo_name=$(task_repo "$id")
  [[ -n "$repo_name" ]] || return 0
  local rpath
  rpath=$(repo_path "$repo_name")
  [[ -n "$rpath" ]] || return 0

  local encoded="${rpath//\//-}"
  encoded="${encoded// /-}"
  local proj_dir="$HOME/.claude/projects/${encoded}"
  [[ -d "$proj_dir" ]] || return 0

  # Get all session files sorted by mtime (newest first)
  local -a all_files=()
  local _csf
  while IFS= read -r _csf; do
    [[ -n "$_csf" ]] && all_files+=("$_csf")
  done < <(command ls -t "$proj_dir"/*.jsonl 2>/dev/null)
  [[ ${#all_files[@]} -gt 0 ]] || return 0

  # Build lookup set of UIDs already known to this task
  local -A known_uids=()
  local _csh
  while IFS= read -r _csh; do
    [[ -n "$_csh" ]] && known_uids[$_csh]=1
  done < <(get_session_history "$id")
  local existing_uid
  existing_uid=$(task_field "$id" "session_uid")
  [[ -n "$existing_uid" && "$existing_uid" != "null" ]] && known_uids[$existing_uid]=1

  # Build collision set: UIDs claimed by other tasks in same repo
  local -A collision_uids=()
  local _csc
  while IFS= read -r _csc; do
    [[ -n "$_csc" ]] && collision_uids[$_csc]=1
  done < <(jq -r --arg id "$id" --arg repo "$repo_name" '
    .tasks[] | select(.id != $id and .repo == $repo) |
    ((.session_history // [])[], .session_uid // empty)
  ' "$GLOBAL_STATE" 2>/dev/null)

  # Iterate from oldest to newest so the last push (newest by mtime) becomes active
  local _csi uid
  for (( _csi=${#all_files[@]}-1; _csi>=0; _csi-- )); do
    uid=$(basename "${all_files[$_csi]}" .jsonl)
    [[ -n "${known_uids[$uid]:-}" ]] && continue
    [[ -n "${collision_uids[$uid]:-}" ]] && continue
    push_session_history "$id" "$uid"
    known_uids[$uid]=1
  done
  return 0
}

cmd_init() {
  ensure_global_state
  check_and_migrate
  cmd_repo_add "${PWD}"
}

cmd_add() {
  local title="" repo_name="" worktree_mode=""

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title|-t) [[ $# -gt 1 ]] || die "--title requires a value"; title="$2"; shift 2 ;;
      --title=*) title="${1#*=}"; shift ;;
      --repo|-r) [[ $# -gt 1 ]] || die "--repo requires a value"; repo_name="$2"; shift 2 ;;
      --repo=*) repo_name="${1#*=}"; shift ;;
      --no-worktree) worktree_mode="none"; shift ;;
      -*) die "unknown flag: $1" ;;
      *) die "unexpected argument: $1 (task IDs are now auto-generated)" ;;
    esac
  done

  [[ -n "$title" ]] || title="(untitled)"

  # Repo selection
  if [[ -z "$repo_name" ]]; then
    local repo_count
    repo_count=$(jq '[.repos[] | select(.archived != true)] | length' "$GLOBAL_STATE")
    if [[ "$repo_count" -eq 0 ]]; then
      die "no repos registered; run 'cloard-board repo add <path>' first"
    elif [[ "$repo_count" -eq 1 ]]; then
      repo_name=$(jq -r '[.repos[] | select(.archived != true)][0].name' "$GLOBAL_STATE")
    else
      # Show picker
      echo "${C_CYAN}Select a repo:${C_RESET}"
      local -a repo_list=()
      local idx=1
      while IFS= read -r rn; do
        repo_list+=("$rn")
        echo "  ${idx}) ${rn}"
        idx=$((idx + 1))
      done < <(jq -r '.repos[] | select(.archived != true) | .name' "$GLOBAL_STATE")
      printf "${C_CYAN}Choice [1-${#repo_list[@]}]: ${C_RESET}"
      local choice
      read -r choice
      [[ "$choice" =~ ^[0-9]+$ ]] || die "invalid choice"
      choice=$((choice - 1))
      [[ $choice -ge 0 && $choice -lt ${#repo_list[@]} ]] || die "invalid choice"
      repo_name="${repo_list[$choice]}"
    fi
  fi

  repo_exists "$repo_name" || die "repo '${repo_name}' not registered"

  # Check not archived
  local is_archived
  is_archived=$(jq -r --arg n "$repo_name" '.repos[] | select(.name == $n) | .archived // false' "$GLOBAL_STATE")
  [[ "$is_archived" != "true" ]] || die "repo '${repo_name}' is archived"

  # Check not stale
  local rpath
  rpath=$(repo_path "$repo_name")
  [[ -d "$rpath" ]] || die "repo path not found: $rpath. Run: cloard-board repo update-path $repo_name <new-path>"

  # Determine worktree mode
  if [[ -z "$worktree_mode" ]]; then
    local rtype
    rtype=$(repo_type "$repo_name")
    if [[ "$rtype" == "dir" ]]; then
      worktree_mode="none"
    else
      worktree_mode="worktree"
    fi
  fi

  # Generate ID
  local id
  id=$(_next_task_id)

  # Add task
  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.tasks.XXXXXX")
  local now
  now=$(now_iso)
  jq --arg id "$id" --arg title "$title" --arg now "$now" \
     --arg wm "$worktree_mode" --arg repo "$repo_name" \
    '.tasks += [{
      id: $id,
      title: $title,
      repo: $repo,
      status: "pending",
      branch: (if $wm == "none" then null else ("worktree-" + $id) end),
      worktree: null,
      worktree_mode: $wm,
      pr_number: null,
      pr_url: null,
      created_at: $now,
      started_at: null,
      completed_at: null,
      claude_status: null,
      session_uid: null,
      session_history: []
    }]' "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state

  ok "created ${id} '${title}' in ${repo_name}"
}

cmd_title() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: cloard-board title <id> <new-title>"
  shift
  local new_title="${*:-}"
  [[ -n "$new_title" ]] || die "usage: cloard-board title <id> <new-title>"
  task_exists "$id" || die "task '$id' not found"
  update_task_field "$id" "title" "$new_title"
  ok "renamed task '$id' to '${new_title}'"
}

cmd_session() {
  require_cmd claude

  local session_uid="${1:-}"
  [[ -n "$session_uid" ]] || die "usage: cloard-board session <session-uid> [--repo <name>] [--title \"...\"]"
  # Validate session UID: must be UUID format or hex string (no shell metacharacters)
  if [[ ! "$session_uid" =~ ^[0-9a-fA-F-]+$ ]]; then
    die "invalid session-uid: must be a UUID or hex string"
  fi
  shift

  local repo_name="" title=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo|-r) [[ $# -gt 1 ]] || die "--repo requires a value"; repo_name="$2"; shift 2 ;;
      --title|-t) [[ $# -gt 1 ]] || die "--title requires a value"; title="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  # Auto-detect repo from session file location
  if [[ -z "$repo_name" ]]; then
    repo_name=$(_find_session_repo "$session_uid") || true
  fi

  # If not found, try single-repo default or prompt
  if [[ -z "$repo_name" ]]; then
    local repo_count
    repo_count=$(jq '[.repos[] | select(.archived != true)] | length' "$GLOBAL_STATE")
    if [[ "$repo_count" -eq 1 ]]; then
      repo_name=$(jq -r '[.repos[] | select(.archived != true)][0].name' "$GLOBAL_STATE")
      warn "session not found in any registered repo; defaulting to '${repo_name}'"
    else
      die "could not determine repo for session '${session_uid}'. Use --repo to specify."
    fi
  fi

  repo_exists "$repo_name" || die "repo '${repo_name}' not registered"

  local rpath
  rpath=$(repo_path "$repo_name")
  [[ -d "$rpath" ]] || die "repo path not found: $rpath"

  # Default title: short session UID
  [[ -z "$title" ]] && title="session-${session_uid:0:8}"

  # Create task (always no-worktree since we're attaching an existing session)
  local id
  id=$(_next_task_id)

  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.tasks.XXXXXX")
  local now
  now=$(now_iso)
  jq --arg id "$id" --arg title "$title" --arg now "$now" \
     --arg repo "$repo_name" --arg uid "$session_uid" \
    '.tasks += [{
      id: $id,
      title: $title,
      repo: $repo,
      status: "active",
      branch: null,
      worktree: null,
      worktree_mode: "none",
      pr_number: null,
      pr_url: null,
      created_at: $now,
      started_at: $now,
      completed_at: null,
      claude_status: null,
      session_uid: $uid,
      session_history: [$uid]
    }]' "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state

  # Start in tmux with claude --continue
  ensure_tmux_session

  _tmux_launch_claude "$id" "$rpath" "claude --resume ${session_uid} --dangerously-skip-permissions"

  ok "tracking session '${session_uid:0:8}...' as ${id} in ${repo_name}"

  if [[ -z "${TMUX:-}" ]]; then
    tmux_cmd attach -t "board:${id}"
  else
    tmux_select_window "$id"
  fi
}

cmd_list() {
  local filter_repo=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo|-r) filter_repo="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local task_data
  if [[ -n "$filter_repo" ]]; then
    task_data=$(jq -r --arg r "$filter_repo" \
      '.tasks[] | select(.repo == $r) | [.id, (.repo // ""), .status, .title, (.claude_status // ""), (.pr_url // "")] | join("\u001e")' \
      "$GLOBAL_STATE")
  else
    task_data=$(jq -r \
      '.tasks[] | [.id, (.repo // ""), .status, .title, (.claude_status // ""), (.pr_url // "")] | join("\u001e")' \
      "$GLOBAL_STATE")
  fi

  if [[ -z "$task_data" ]]; then
    info "no tasks yet; run 'cloard-board add --title \"...\"' to create one"
    return 0
  fi

  # Print table header
  printf "\n${C_BOLD}%-10s %-15s %-15s %-35s %-12s %-10s${C_RESET}\n" "ID" "REPO" "STATUS" "TITLE" "CLAUDE" "PR"
  printf "%-10s %-15s %-15s %-35s %-12s %-10s\n" \
    "$(printf '%0.s─' {1..10})" "$(printf '%0.s─' {1..15})" "$(printf '%0.s─' {1..15})" \
    "$(printf '%0.s─' {1..35})" "$(printf '%0.s─' {1..12})" "$(printf '%0.s─' {1..10})"

  while IFS=$'\x1e' read -r t_id t_repo t_status t_title t_claude t_pr; do
    [[ -n "$t_id" ]] || continue
    local color="$C_RESET"
    case "$t_status" in
      pending)      color="$C_DIM" ;;
      paused)       color="$C_CYAN" ;;
      active)       color="$C_GREEN" ;;
      needs_review) color="$C_YELLOW" ;;
      done)         color="$C_DIM" ;;
    esac
    local pr_display=""
    if [[ -n "$t_pr" ]]; then
      pr_display=$(echo "$t_pr" | grep -oE '#[0-9]+' || echo "$t_pr")
    fi
    local claude_display=""
    [[ "$t_claude" == "working" ]] && claude_display="● working"
    [[ "$t_claude" == "waiting" ]] && claude_display="○ waiting"
    printf "${color}%-10s %-15s %-15s %-35s %-12s %-10s${C_RESET}\n" \
      "$t_id" "${t_repo:0:15}" "$t_status" "${t_title:0:35}" "$claude_display" "$pr_display"
  done <<< "$task_data"
  echo
}

cmd_start() {
  require_cmd claude

  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: cloard-board start <id> [prompt]"
  shift
  local prompt="${*:-}"

  task_exists "$id" || die "task '$id' not found; run 'cloard-board add' first"

  local tsk_status
  tsk_status=$(task_status "$id")
  [[ "$tsk_status" == "pending" ]] || die "task '$id' is '${tsk_status}', not 'pending'"

  # Look up repo
  local repo_name
  repo_name=$(task_repo "$id")
  [[ -n "$repo_name" ]] || die "task '$id' has no repo assigned"

  local rpath
  rpath=$(repo_path "$repo_name")
  [[ -d "$rpath" ]] || die "repo path not found: $rpath. Run: cloard-board repo update-path $repo_name <new-path>"

  local rtype
  rtype=$(repo_type "$repo_name")

  ensure_tmux_session

  local session_uid=""

  if tmux_window_exists "$id"; then
    warn "tmux window '$id' already exists; switching to it"
    tmux_select_window "$id"
  else
    local wt_mode
    wt_mode=$(jq -r --arg id "$id" '.tasks[] | select(.id == $id) | .worktree_mode // "worktree"' "$GLOBAL_STATE")

    # Force no-worktree for non-git repos
    [[ "$rtype" == "dir" ]] && wt_mode="none"

    # Generate session ID for reliable resumption
    session_uid=$(uuidgen | tr '[:upper:]' '[:lower:]')

    local claude_cmd

    if [[ "$wt_mode" == "none" ]]; then
      claude_cmd="claude --session-id ${session_uid} --dangerously-skip-permissions"
    else
      claude_cmd="claude --worktree ${id} --session-id ${session_uid} --dangerously-skip-permissions"
    fi

    if [[ -n "$prompt" ]]; then
      local escaped_prompt="${prompt//\'/\'\\\'\'}"
      claude_cmd="${claude_cmd} '${escaped_prompt}'"
    fi

    _tmux_launch_claude "$id" "$rpath" "$claude_cmd"

    if [[ "$wt_mode" == "none" ]]; then
      info "created tmux window '${id}' with claude (no worktree) in ${repo_name}"
    else
      info "created tmux window '${id}' with claude --worktree in ${repo_name}"
    fi
  fi

  # Update state
  update_task_field "$id" "status" "active"
  update_task_field "$id" "started_at" "$(now_iso)"
  [[ -n "$session_uid" ]] && push_session_history "$id" "$session_uid"

  # Try to discover worktree path
  local wt_path
  wt_path=$(find_worktree_path "$id" "$rpath")
  if [[ -n "$wt_path" ]]; then
    update_task_field "$id" "worktree" "$wt_path"
  fi

  ok "started task '${id}' in ${repo_name}"

  # Attach if not already in tmux
  if [[ -z "${TMUX:-}" ]]; then
    tmux_cmd attach -t "board:${id}"
  else
    tmux_select_window "$id"
  fi
}

cmd_go() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: cloard-board go <id>"
  task_exists "$id" || die "task '$id' not found"

  ensure_tmux_session

  if ! tmux_window_exists "$id"; then
    die "no tmux window for task '${id}'; try 'cloard-board start' or 'cloard-board resume'"
  fi

  if [[ -z "${TMUX:-}" ]]; then
    tmux_cmd attach -t "board:${id}"
  else
    tmux_select_window "$id"
  fi
}

cmd_attach() {
  if ! tmux_session_exists; then
    die "no cloard-board tmux session; run 'cloard-board start' or 'cloard-board dash' first"
  fi
  if [[ -z "${TMUX:-}" ]]; then
    tmux_cmd attach -t "board"
  else
    warn "already inside tmux; use 'cloard-board go <id>' or 'cloard-board dash'"
  fi
}

cmd_advance() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: cloard-board advance <id>"
  task_exists "$id" || die "task '$id' not found"

  local tsk_status
  tsk_status=$(task_status "$id")

  case "$tsk_status" in
    pending)
      info "advancing '${id}': pending -> active"
      cmd_start "$id"
      ;;
    paused)
      info "advancing '${id}': paused -> active (resuming)"
      cmd_resume "$id"
      ;;
    active)
      update_task_field "$id" "status" "needs_review"
      update_task_field_raw "$id" "claude_status" "null"
      ok "advanced '${id}': active -> needs_review"
      ;;
    needs_review)
      info "advancing '${id}': needs_review -> done"
      cmd_done "$id"
      ;;
    done)
      warn "task '${id}' is already done"
      ;;
  esac
}

cmd_done() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: cloard-board done <id>"
  task_exists "$id" || die "task '$id' not found"

  # Kill tmux window
  tmux_kill_window "$id"

  local wt_mode
  wt_mode=$(jq -r --arg id "$id" '.tasks[] | select(.id == $id) | .worktree_mode // "worktree"' "$GLOBAL_STATE")

  if [[ "$wt_mode" != "none" ]]; then
    local repo_name
    repo_name=$(task_repo "$id")
    local rpath
    rpath=$(repo_path "$repo_name")

    if [[ -d "$rpath" ]]; then
      # Remove worktree
      local wt_path
      wt_path=$(find_worktree_path "$id" "$rpath")
      if [[ -n "$wt_path" ]]; then
        info "removing worktree at ${wt_path}"
        (cd "$rpath" && git worktree remove "$wt_path" --force 2>/dev/null) || \
          warn "could not remove worktree (may need manual cleanup)"
      fi

      # Delete local branch
      local branch="worktree-${id}"
      (cd "$rpath" && git branch -D "$branch" 2>/dev/null) || true
    fi
  fi

  update_task_field "$id" "status" "done"
  update_task_field "$id" "completed_at" "$(now_iso)"
  update_task_field_raw "$id" "claude_status" "null"

  ok "task '${id}' marked done; window and worktree cleaned up"
}

cmd_reopen() {
  require_cmd claude

  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: cloard-board reopen <id>"
  task_exists "$id" || die "task '$id' not found"

  local tsk_status
  tsk_status=$(task_status "$id")
  [[ "$tsk_status" == "done" ]] || die "task '$id' is '${tsk_status}'; only 'done' tasks can be reopened"

  # Look up repo
  local repo_name
  repo_name=$(task_repo "$id")
  local rpath
  rpath=$(repo_path "$repo_name")
  [[ -d "$rpath" ]] || die "repo path not found: $rpath"

  local safe_global_dir=${(q)GLOBAL_DIR}
  local safe_repo_path=${(q)rpath}
  local safe_work_dir=${(q)rpath}

  ensure_tmux_session

  if tmux_window_exists "$id"; then
    info "window '${id}' already exists; switching to it"
  else
    # Worktree was removed by cmd_done, so always work from repo root
    local reopen_prompt="${2:-}"
    local dash_claude_cmd
    if [[ -n "$reopen_prompt" ]]; then
      local escaped="${reopen_prompt//\'/\'\\\'\'}"
      dash_claude_cmd="claude --dangerously-skip-permissions '${escaped}'"
    else
      dash_claude_cmd=$(_build_claude_resume_cmd "$id")
    fi
    _tmux_launch_claude "$id" "$rpath" "$dash_claude_cmd"
    info "reopened task '${id}' with claude resume (from repo root)"
  fi

  # Update state: reactivate the task
  update_task_field "$id" "status" "active"
  update_task_field "$id" "worktree_mode" "none"
  update_task_field_raw "$id" "branch" "null"
  update_task_field_raw "$id" "completed_at" "null"

  if [[ -z "${TMUX:-}" ]]; then
    tmux_cmd attach -t "board:${id}"
  else
    tmux_select_window "$id"
  fi

  ok "task '${id}' reopened"
}

cmd_pause() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: cloard-board pause <id>"
  task_exists "$id" || die "task '$id' not found"

  local tsk_status
  tsk_status=$(task_status "$id")
  [[ "$tsk_status" == "active" || "$tsk_status" == "needs_review" ]] || \
    die "task '$id' is '${tsk_status}'; must be 'active' or 'needs_review' to pause"

  tmux_kill_window "$id"
  update_task_field "$id" "status" "paused"
  update_task_field_raw "$id" "claude_status" "null"

  ok "paused task '${id}'; worktree and branch preserved"
}

cmd_resume() {
  require_cmd claude

  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: cloard-board resume <id>"
  task_exists "$id" || die "task '$id' not found"

  local tsk_status
  tsk_status=$(task_status "$id")
  [[ "$tsk_status" != "done" ]] || die "task '$id' is done; nothing to resume"

  # Look up repo
  local repo_name
  repo_name=$(task_repo "$id")
  local rpath
  rpath=$(repo_path "$repo_name")
  [[ -d "$rpath" ]] || die "repo path not found: $rpath"

  local wt_mode
  wt_mode=$(jq -r --arg id "$id" '.tasks[] | select(.id == $id) | .worktree_mode // "worktree"' "$GLOBAL_STATE")

  local safe_global_dir=${(q)GLOBAL_DIR}
  local safe_repo_path=${(q)rpath}

  ensure_tmux_session

  # Kill dead windows (Claude exited, bare zsh running)
  if tmux_window_exists "$id" && ! _tmux_claude_alive "$id"; then
    tmux_kill_window "$id"
  fi

  if _tmux_claude_alive "$id"; then
    info "window '${id}' already exists; switching to it"
  else
    local resume_cmd
    resume_cmd=$(_build_claude_resume_cmd "$id")
    if [[ "$wt_mode" == "none" ]]; then
      _tmux_launch_claude "$id" "$rpath" "$resume_cmd"
      info "created tmux window '${id}' with claude resume (no worktree)"
    else
      local wt_path
      wt_path=$(find_worktree_path "$id" "$rpath")
      if [[ -z "$wt_path" ]]; then
        die "no worktree found for '${id}'; use 'cloard-board start' instead"
      fi
      _tmux_launch_claude "$id" "$wt_path" "$resume_cmd"
      info "created tmux window '${id}' with claude resume"
    fi
  fi

  # Ensure status is active
  if [[ "$tsk_status" != "active" ]]; then
    update_task_field "$id" "status" "active"
  fi

  if [[ -z "${TMUX:-}" ]]; then
    tmux_cmd attach -t "board:${id}"
  else
    tmux_select_window "$id"
  fi
}

cmd_rm() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: cloard-board rm <id>"
  task_exists "$id" || die "task '$id' not found"

  local tsk_status
  tsk_status=$(task_status "$id")

  # Clean up resources for any non-done status
  if [[ "$tsk_status" != "done" ]]; then
    tmux_kill_window "$id"
    local wt_mode
    wt_mode=$(jq -r --arg id "$id" '.tasks[] | select(.id == $id) | .worktree_mode // "worktree"' "$GLOBAL_STATE")
    if [[ "$wt_mode" != "none" ]]; then
      local repo_name
      repo_name=$(task_repo "$id")
      local rpath
      rpath=$(repo_path "$repo_name")
      if [[ -d "$rpath" ]]; then
        local wt_path
        wt_path=$(find_worktree_path "$id" "$rpath")
        if [[ -n "$wt_path" ]]; then
          (cd "$rpath" && git worktree remove "$wt_path" --force 2>/dev/null) || true
        fi
        (cd "$rpath" && git branch -D "worktree-${id}" 2>/dev/null) || true
      fi
    fi
  fi

  # Remove from JSON
  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.tasks.XXXXXX")
  jq --arg id "$id" '.tasks = [.tasks[] | select(.id != $id)]' "$GLOBAL_STATE" > "$tmp" \
    && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state

  ok "removed task '${id}'"
}

cmd_status() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "usage: cloard-board status <id>"
  task_exists "$id" || die "task '$id' not found"

  local tsk_status claude_status title repo_name
  tsk_status=$(task_status "$id")
  claude_status=$(task_field "$id" "claude_status")
  title=$(task_field "$id" "title")
  repo_name=$(task_repo "$id")

  echo "${C_BOLD}${id}${C_RESET}: ${title}"
  echo "  repo:   ${repo_name}"
  echo "  task:   ${tsk_status}"
  if [[ "$claude_status" == "working" ]]; then
    echo "  claude: ${C_GREEN}● working${C_RESET}"
  elif [[ "$claude_status" == "waiting" ]]; then
    echo "  claude: ${C_YELLOW}○ waiting${C_RESET}"
  else
    echo "  claude: ${C_DIM}no status${C_RESET}"
  fi
}

cmd_signal() {
  # Fast path for hooks: no ensure_global_state, just check file exists
  [[ -f "$GLOBAL_STATE" ]] || return 0

  local id="${1:-}"
  local signal="${2:-}"

  [[ -n "$id" ]] || { warn "usage: cloard-board signal <id> <working|waiting|clear>"; return 1; }
  [[ -n "$signal" ]] || { warn "usage: cloard-board signal <id> <working|waiting|clear>"; return 1; }

  if ! task_exists "$id"; then
    return 0
  fi

  case "$signal" in
    working)
      local tsk_status
      tsk_status=$(task_status "$id")
      if [[ "$tsk_status" == "active" || "$tsk_status" == "needs_review" ]]; then
        update_task_field "$id" "claude_status" "$signal"
        # If task was moved to needs_review by a previous "waiting" signal, move it back
        if [[ "$tsk_status" == "needs_review" ]]; then
          update_task_field "$id" "status" "active"
        fi
      fi
      ;;
    waiting)
      local tsk_status
      tsk_status=$(task_status "$id")
      if [[ "$tsk_status" == "active" ]]; then
        update_task_field "$id" "claude_status" "$signal"
        # Auto-move to needs_review when Claude is waiting
        update_task_field "$id" "status" "needs_review"
      fi
      ;;
    clear)
      update_task_field_raw "$id" "claude_status" "null"
      ;;
    *)
      warn "unknown signal: ${signal}; expected working, waiting, or clear"
      return 1
      ;;
  esac
}

cmd_doctor() {
  local issues=0

  info "checking cloard-board health..."

  # Check each repo
  local repo_data
  repo_data=$(jq -r '.repos[] | [.name, .path, (.type // "git")] | join("\u001e")' "$GLOBAL_STATE")

  while IFS=$'\x1e' read -r rname rpath rtype; do
    [[ -n "$rname" ]] || continue

    if [[ ! -d "$rpath" ]]; then
      warn "repo '${rname}': path not found (${rpath})"
      issues=$((issues + 1))
      continue
    fi

    # Check worktrees for git repos
    if [[ "$rtype" == "git" ]]; then
      while IFS= read -r line; do
        if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
          local wt_path="${match[0]}"
        elif [[ "$line" =~ ^branch\ refs/heads/worktree-(.+)$ ]]; then
          local wt_id="${match[0]}"
          if ! task_exists "$wt_id"; then
            warn "orphaned worktree in '${rname}': ${wt_path} (branch worktree-${wt_id})"
            issues=$((issues + 1))
          fi
        fi
      done < <(cd "$rpath" && git worktree list --porcelain 2>/dev/null)
    fi
  done <<< "$repo_data"

  # Check for active tasks with no tmux window
  while read -r tid; do
    [[ -z "$tid" ]] && continue
    if ! tmux_window_exists "$tid" 2>/dev/null; then
      warn "task '${tid}' is active but has no tmux window"
      issues=$((issues + 1))
    fi
  done < <(jq -r '.tasks[] | select(.status == "active") | .id' "$GLOBAL_STATE")

  # Check for tmux windows with no matching task (skip cron windows)
  if tmux_session_exists; then
    while read -r wname; do
      [[ -z "$wname" || "$wname" == "dashboard" ]] && continue
      [[ "$wname" == cron-* || "$wname" == resume-* ]] && continue
      if ! task_exists "$wname"; then
        warn "orphaned tmux window: '${wname}' (no matching task)"
        issues=$((issues + 1))
      fi
    done < <(tmux_cmd list-windows -t "board" -F '#{window_name}' 2>/dev/null)
  fi

  # Check cron jobs health
  local cron_count
  cron_count=$(jq '.cron_jobs | length' "$GLOBAL_STATE" 2>/dev/null) || cron_count=0
  if [[ "$cron_count" -gt 0 ]]; then
    info "checking ${cron_count} cron job(s)..."

    # Check for missing plist files
    while IFS=$'\x1e' read -r cid cplist; do
      [[ -n "$cid" ]] || continue
      if [[ -n "$cplist" && ! -f "$cplist" ]]; then
        warn "cron job '${cid}': plist not found (${cplist})"
        issues=$((issues + 1))
      fi
    done < <(jq -r '.cron_jobs[] | [.id, .plist_path] | join("\u001e")' "$GLOBAL_STATE")

    # Prune old archived/reviewed runs (older than 7 days)
    local prune_cutoff
    prune_cutoff=$(date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '7 days ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || true
    if [[ -n "$prune_cutoff" ]]; then
      local prune_count
      prune_count=$(jq -r --arg cutoff "$prune_cutoff" '
        [.cron_runs[] | select((.status == "archived" or .status == "reviewed") and .completed_at != null and .completed_at < $cutoff)] | length
      ' "$GLOBAL_STATE" 2>/dev/null) || prune_count=0
      if [[ "$prune_count" -gt 0 ]]; then
        info "pruning ${prune_count} old cron run(s)..."
        _lock_state || true
        local tmp
        tmp=$(mktemp "${GLOBAL_DIR}/.cron.XXXXXX")
        jq --arg cutoff "$prune_cutoff" '
          .cron_runs = [.cron_runs[] | select(
            not((.status == "archived" or .status == "reviewed") and .completed_at != null and .completed_at < $cutoff)
          )]
        ' "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
        _unlock_state
        ok "pruned ${prune_count} old run(s)"
      fi
    fi

    # Archive stale needs_review runs
    _archive_stale_cron_runs
  fi

  if [[ "$issues" -eq 0 ]]; then
    ok "all clear; no issues found"
  else
    warn "${issues} issue(s) found"
  fi
}

