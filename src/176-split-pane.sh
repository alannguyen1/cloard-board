# ── Split-pane lifecycle (list mode sidebar + Claude session) ─────────────────

# Helper: build the Claude launch command and work directory for a task.
# Sets dynamic-scoped variables _sbc_cmd and _sbc_dir for the caller.
_split_build_cmd() {
  local task_id="$1"
  local tst="${_task_status[$task_id]}"
  local repo_name="${_task_repo[$task_id]}"
  local rpath
  rpath=$(repo_path "$repo_name")
  local wt_mode="${_task_wtmode[$task_id]}"

  # Default work directory to repo root
  _sbc_dir="$rpath"

  # Try worktree path if applicable
  if [[ "$wt_mode" != "none" ]]; then
    local wt_path
    wt_path=$(find_worktree_path "$task_id" "$rpath")
    [[ -n "$wt_path" ]] && _sbc_dir="$wt_path"
  fi

  if [[ "$tst" == "pending" ]]; then
    # New session: generate UUID, update state
    local session_uid
    session_uid=$(uuidgen | tr '[:upper:]' '[:lower:]')

    if [[ "$wt_mode" == "none" ]]; then
      _sbc_cmd="claude --session-id ${session_uid} --dangerously-skip-permissions"
    else
      _sbc_cmd="claude --worktree ${task_id} --session-id ${session_uid} --dangerously-skip-permissions"
    fi

    update_task_field "$task_id" "status" "active"
    update_task_field "$task_id" "started_at" "$(now_iso)"
    push_session_history "$task_id" "$session_uid"
  elif [[ "$tst" == "paused" ]]; then
    update_task_field "$task_id" "status" "active"
    _sbc_cmd=$(_build_claude_resume_cmd "$task_id")
  elif [[ "$tst" == "done" ]]; then
    update_task_field "$task_id" "status" "active"
    update_task_field "$task_id" "worktree_mode" "none"
    update_task_field_raw "$task_id" "branch" "null"
    update_task_field_raw "$task_id" "completed_at" "null"
    _sbc_cmd=$(_build_claude_resume_cmd "$task_id")
  else
    # active, needs_review: just resume
    _sbc_cmd=$(_build_claude_resume_cmd "$task_id")
  fi
}

# Kill all stale (dead Claude) windows for a task, keeping any live one.
# Prevents duplicate windows from accumulating across split-pane switches.
_purge_stale_windows() {
  local name="$1"
  local _pw_i=0
  while [[ $_pw_i -lt 50 ]] && tmux_window_exists "$name" && ! _tmux_claude_alive "$name"; do
    tmux_kill_window "$name"
    _pw_i=$((_pw_i + 1))
  done
}

# Install/remove tmux keybinding for returning to sidebar from the Claude pane.
_split_bind_sidebar_key() {
  tmux_cmd bind-key -T prefix h select-pane -t "board:dashboard.0" 2>/dev/null || true
}
_split_unbind_sidebar_key() {
  tmux_cmd unbind-key -T prefix h 2>/dev/null || true
}

# Open a split pane with the task's Claude session on the right side.
_split_open() {
  local task_id="$1"
  local repo_name="${_task_repo[$task_id]}"

  # Bail if repo is stale (directory missing)
  if [[ "${_repo_stale[$repo_name]}" == "1" ]]; then
    return 1
  fi

  _split_active=1
  _split_task_id="$task_id"
  _split_bind_sidebar_key

  # Clean up stale windows before checking for a live one
  _purge_stale_windows "$task_id"

  if tmux_window_exists "$task_id"; then
    # Live session found: join it into the dashboard as right pane
    tmux_cmd join-pane -h -s "board:${task_id}.0" -t "board:dashboard" -l '60%' 2>/dev/null || true
    tmux_cmd select-pane -t "board:dashboard.0" 2>/dev/null || true
    return 0
  fi

  # Build command and work directory
  local _sbc_cmd="" _sbc_dir=""
  _split_build_cmd "$task_id"

  local safe_global_dir=${(q)GLOBAL_DIR}
  local safe_work_dir=${(q)_sbc_dir}

  tmux_cmd split-window -h -t "board:dashboard" -p 60 \
    "export CLOARD_TASK_ID=${task_id} CLOARD_BOARD_DIR=${safe_global_dir} && cd ${safe_work_dir} && ${_sbc_cmd}; zsh; tmux -L cloard-board select-window -t board:dashboard 2>/dev/null"

  tmux_cmd select-pane -t "board:dashboard.0" 2>/dev/null || true
}

# Switch the right pane to a different task's session.
_split_switch_session() {
  local new_task_id="$1"

  # Preserve the current session by breaking it out to its own window
  if [[ -n "$_split_task_id" ]]; then
    # Kill stale windows first so break-pane creates the only named window
    _purge_stale_windows "$_split_task_id"
    tmux_cmd break-pane -d -s "board:dashboard.1" -n "$_split_task_id" 2>/dev/null || true
  fi

  _split_task_id="$new_task_id"
  local repo_name="${_task_repo[$new_task_id]}"

  # Bail if repo is stale
  if [[ "${_repo_stale[$repo_name]}" == "1" ]]; then
    _split_active=0
    _split_task_id=""
    return 1
  fi

  # Clean up stale windows for the target task
  _purge_stale_windows "$new_task_id"

  if tmux_window_exists "$new_task_id"; then
    # Live session found: join it
    tmux_cmd join-pane -h -s "board:${new_task_id}.0" -t "board:dashboard" -l '60%' 2>/dev/null || true
    tmux_cmd select-pane -t "board:dashboard.0" 2>/dev/null || true
    return 0
  fi

  # Build command and work directory for the new task
  local _sbc_cmd="" _sbc_dir=""
  _split_build_cmd "$new_task_id"

  local safe_global_dir=${(q)GLOBAL_DIR}
  local safe_work_dir=${(q)_sbc_dir}

  tmux_cmd split-window -h -t "board:dashboard" -p 60 \
    "export CLOARD_TASK_ID=${new_task_id} CLOARD_BOARD_DIR=${safe_global_dir} && cd ${safe_work_dir} && ${_sbc_cmd}; zsh; tmux -L cloard-board select-window -t board:dashboard 2>/dev/null"

  tmux_cmd select-pane -t "board:dashboard.0" 2>/dev/null || true
}

# Close the split view, preserving the running session in its own tmux window.
_split_close() {
  if [[ -n "$_split_task_id" ]]; then
    # Kill stale windows first so break-pane creates the only named window
    _purge_stale_windows "$_split_task_id"
    # Try to preserve as named window; fall back to killing the pane
    tmux_cmd break-pane -d -s "board:dashboard.1" -n "$_split_task_id" 2>/dev/null \
      || tmux_cmd kill-pane -t "board:dashboard.1" 2>/dev/null \
      || true
  fi
  _split_active=0
  _split_task_id=""
  _split_unbind_sidebar_key
}
