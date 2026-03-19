# ── Split-pane lifecycle (list mode sidebar + Claude session) ─────────────────

# Helper: build the Claude launch command and work directory for a task.
# Sets dynamic-scoped variables _sbc_cmd and _sbc_dir for the caller.
_split_build_cmd() {
  local task_id="$1"
  local tst="${_task_status[$task_id]:-}"
  # Fallback to live state when snapshot is stale (e.g. task just created by modal)
  if [[ -z "$tst" ]]; then
    tst=$(task_status "$task_id")
  fi
  local repo_name="${_task_repo[$task_id]:-}"
  if [[ -z "$repo_name" ]]; then
    repo_name=$(task_field "$task_id" "repo")
  fi
  local rpath
  rpath=$(repo_path "$repo_name")
  local wt_mode="${_task_wtmode[$task_id]:-}"
  if [[ -z "$wt_mode" ]]; then
    wt_mode=$(task_field "$task_id" "worktree_mode")
  fi

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

    # Append initial prompt if set by caller (dynamic-scoped)
    if [[ -n "${_split_initial_prompt:-}" ]]; then
      local escaped_prompt="${_split_initial_prompt//\'/\'\\\'\'}"
      _sbc_cmd="${_sbc_cmd} '${escaped_prompt}'"
    fi

    set_task_status "$task_id" "active"
    update_task_field "$task_id" "started_at" "$(now_iso)"
    push_session_history "$task_id" "$session_uid"
  elif [[ "$tst" == "paused" ]]; then
    set_task_status "$task_id" "active"
    _sbc_cmd=$(_build_claude_resume_cmd "$task_id")
  elif [[ "$tst" == "done" ]]; then
    set_task_status "$task_id" "active"
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
  tmux_cmd bind-key -T root C-f if-shell -F "#{>:#{window_panes},1}" "last-pane" 2>/dev/null || true
}
_split_unbind_sidebar_key() {
  tmux_cmd unbind-key -T root C-f 2>/dev/null || true
}

# Open a split pane with the task's Claude session on the right side.
_split_open() {
  local task_id="$1"
  local repo_name="${_task_repo[$task_id]:-}"
  if [[ -z "$repo_name" ]]; then
    repo_name=$(task_field "$task_id" "repo")
  fi

  # Bail if repo is stale (directory missing)
  if [[ "${_repo_stale[$repo_name]}" == "1" ]]; then
    return 1
  fi

  _split_active=1
  _split_task_id="$task_id"
  _split_is_cron=0
  _split_bind_sidebar_key

  # Clean up stale windows before checking for a live one
  _purge_stale_windows "$task_id"

  if tmux_window_exists "$task_id"; then
    # Live session found: join it into the dashboard as right pane
    tmux_cmd join-pane -h -s "board:${task_id}.0" -t "board:dashboard" -l '60%' 2>/dev/null || true
    _tmux_mark_task_pane "board:dashboard.1" "$task_id"
    tmux_cmd select-pane -t "board:dashboard.1" 2>/dev/null || true
    return 0
  fi

  # Build command and work directory
  local _sbc_cmd="" _sbc_dir=""
  _split_build_cmd "$task_id"

  local safe_global_dir=${(q)GLOBAL_DIR}
  local safe_work_dir=${(q)_sbc_dir}

  tmux_cmd split-window -h -t "board:dashboard" -p 60 \
    "export CLOARD_TASK_ID=${task_id} CLOARD_BOARD_DIR=${safe_global_dir} && cd ${safe_work_dir} && ${_sbc_cmd}; zsh; tmux -L cloard-board select-window -t board:dashboard 2>/dev/null"

  _tmux_mark_task_pane "board:dashboard.1" "$task_id"
  tmux_cmd select-pane -t "board:dashboard.1" 2>/dev/null || true
}

# Open a split pane with a cron run's Claude session on the right side.
_split_open_cron() {
  local cron_id="$1"
  local rdata="${_cron_run_data[$cron_id]:-}"

  # Only works for cron runs with data (not scheduled jobs)
  [[ -n "$rdata" ]] || return 1

  local rjob_id rstat recode rstart rsid rwin
  IFS=$'\x1e' read -r rjob_id rstat recode rstart rsid rwin <<< "$(echo -e "$rdata")"

  _split_active=1
  _split_task_id="$cron_id"
  _split_is_cron=1
  _split_bind_sidebar_key

  ensure_tmux_session

  # Active run with live tmux window: join it into dashboard right pane
  if [[ "$rstat" == "active" && -n "$rwin" ]] && tmux_window_exists "$rwin"; then
    tmux_cmd join-pane -h -s "board:${rwin}.0" -t "board:dashboard" -l '60%' 2>/dev/null || true
    tmux_cmd select-pane -t "board:dashboard.1" 2>/dev/null || true
    return 0
  fi

  # Resume from session ID
  if [[ -n "$rsid" ]]; then
    local cjob_wdir
    cjob_wdir=$(cron_job_field "$rjob_id" "working_dir")
    local safe_wdir=${(q)cjob_wdir}
    local resume_win="resume-${cron_id}"

    # Check for existing resume window
    _purge_stale_windows "$resume_win"
    if tmux_window_exists "$resume_win"; then
      tmux_cmd join-pane -h -s "board:${resume_win}.0" -t "board:dashboard" -l '60%' 2>/dev/null || true
    else
      tmux_cmd split-window -h -t "board:dashboard" -p 60 \
        "cd ${safe_wdir} && claude --resume ${rsid}; zsh; tmux -L cloard-board select-window -t board:dashboard 2>/dev/null"
    fi
    tmux_cmd select-pane -t "board:dashboard.1" 2>/dev/null || true
  fi
}

# Switch the right pane to a different task's session.
# Uses swap-pane for atomic switching (no layout change = no flicker).
_split_switch_session() {
  local new_task_id="$1"
  local old_task_id="$_split_task_id"

  _split_task_id="$new_task_id"
  local repo_name="${_task_repo[$new_task_id]:-}"
  if [[ -z "$repo_name" ]]; then
    repo_name=$(task_field "$new_task_id" "repo")
  fi

  # Bail if repo is stale
  if [[ "${_repo_stale[$repo_name]}" == "1" ]]; then
    _split_active=0
    _split_task_id=""
    return 1
  fi

  # Clean up stale windows for the target task
  _purge_stale_windows "$new_task_id"

  if tmux_window_exists "$new_task_id"; then
    # Live session found: atomic swap into the right pane
    if tmux_cmd swap-pane -d -s "board:dashboard.1" -t "board:${new_task_id}.0" 2>/dev/null; then
      # The window formerly named $new_task_id now holds the old pane content;
      # rename it to the old task ID so it can be found later.
      if [[ -n "$old_task_id" ]]; then
        tmux_cmd rename-window -t "board:${new_task_id}" "$old_task_id" 2>/dev/null || true
        _purge_stale_windows "$old_task_id"
      fi
      _tmux_mark_task_pane "board:dashboard.1" "$new_task_id"
      tmux_cmd select-pane -t "board:dashboard.1" 2>/dev/null || true
      return 0
    fi
    # swap-pane failed; fall through to break+join fallback
  fi

  # -- Fallback / no existing window --
  # Preserve the current session by breaking it out to its own window
  if [[ -n "$old_task_id" ]]; then
    _purge_stale_windows "$old_task_id"
    tmux_cmd break-pane -d -s "board:dashboard.1" -n "$old_task_id" 2>/dev/null || true
  fi

  # Re-check: purge may have cleaned up, and a window might still exist
  _purge_stale_windows "$new_task_id"

  if tmux_window_exists "$new_task_id"; then
    # Live session found after fallback: join it
    tmux_cmd join-pane -h -s "board:${new_task_id}.0" -t "board:dashboard" -l '60%' 2>/dev/null || true
    _tmux_mark_task_pane "board:dashboard.1" "$new_task_id"
    tmux_cmd select-pane -t "board:dashboard.1" 2>/dev/null || true
    return 0
  fi

  # No existing window: build command and create a new split
  local _sbc_cmd="" _sbc_dir=""
  _split_build_cmd "$new_task_id"

  local safe_global_dir=${(q)GLOBAL_DIR}
  local safe_work_dir=${(q)_sbc_dir}

  tmux_cmd split-window -h -t "board:dashboard" -p 60 \
    "export CLOARD_TASK_ID=${new_task_id} CLOARD_BOARD_DIR=${safe_global_dir} && cd ${safe_work_dir} && ${_sbc_cmd}; zsh; tmux -L cloard-board select-window -t board:dashboard 2>/dev/null"

  _tmux_mark_task_pane "board:dashboard.1" "$new_task_id"
  tmux_cmd select-pane -t "board:dashboard.1" 2>/dev/null || true
}

# Close the split view, preserving the running session in its own tmux window.
_split_close() {
  if [[ -n "$_split_task_id" ]]; then
    # For cron splits, preserve with resume- prefix so _split_open_cron can find it
    local break_name="$_split_task_id"
    if [[ "${_split_is_cron:-0}" == "1" ]]; then
      break_name="resume-${_split_task_id}"
    fi
    # Kill stale windows first so break-pane creates the only named window
    _purge_stale_windows "$break_name"
    # Try to preserve as named window; fall back to killing the pane
    tmux_cmd break-pane -d -s "board:dashboard.1" -n "$break_name" 2>/dev/null \
      || tmux_cmd kill-pane -t "board:dashboard.1" 2>/dev/null \
      || true
  fi
  _split_active=0
  _split_task_id=""
  _split_is_cron=0
  _split_unbind_sidebar_key
}
