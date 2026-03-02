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
    update_task_field "$task_id" "session_uid" "$session_uid"
  else
    # Resume existing session (active, paused, needs_review, done)
    _sbc_cmd=$(_build_claude_resume_cmd "$task_id")
  fi
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

  if tmux_window_exists "$task_id"; then
    if _tmux_claude_alive "$task_id"; then
      # Existing live session: join it into the dashboard as right pane
      tmux_cmd join-pane -h -s "board:${task_id}.0" -t "board:dashboard" -l '60%' 2>/dev/null || true
      tmux_cmd select-pane -t "board:dashboard.0" 2>/dev/null || true
      return 0
    else
      # Dead window (Claude exited, bare zsh): clean up first
      tmux_kill_window "$task_id"
    fi
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

  if tmux_window_exists "$new_task_id"; then
    if _tmux_claude_alive "$new_task_id"; then
      tmux_cmd join-pane -h -s "board:${new_task_id}.0" -t "board:dashboard" -l '60%' 2>/dev/null || true
      tmux_cmd select-pane -t "board:dashboard.0" 2>/dev/null || true
      return 0
    else
      tmux_kill_window "$new_task_id"
    fi
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
    # Try to preserve as named window; fall back to killing the pane
    tmux_cmd break-pane -d -s "board:dashboard.1" -n "$_split_task_id" 2>/dev/null \
      || tmux_cmd kill-pane -t "board:dashboard.1" 2>/dev/null \
      || true
  fi
  _split_active=0
  _split_task_id=""
  _split_unbind_sidebar_key
}
