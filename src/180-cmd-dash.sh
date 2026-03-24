cmd_dash() {
  ensure_tmux_session

  # If we're not in the cloard-board tmux, launch dashboard in it
  if [[ -z "${TMUX:-}" ]]; then
    cmd__dash_switch
    tmux_cmd attach -t "board:dashboard"
    return
  fi

  # If inside tmux but not in cloard-board socket, warn
  if [[ "${TMUX:-}" != *"${TMUX_SOCKET}"* ]]; then
    warn "you're in a different tmux; run outside tmux or inside cloard-board"
    return 1
  fi

  # Already inside cloard-board tmux; recreate dashboard if needed, then switch
  cmd__dash_switch
}

# Switch to dashboard window, recreating it if closed
cmd__dash_switch() {
  ensure_tmux_session
  if ! tmux_window_exists "dashboard"; then
    tmux_cmd new-window -t "board" -n "dashboard"
    _tmux_dashboard_start_loop
  fi
  tmux_cmd select-window -t "board:dashboard"
}

_dash_toggle_view_mode() {
  if _tmux_dashboard_has_dock; then
    _view_mode="list"
    return 0
  fi

  if [[ "$_view_mode" == "kanban" ]]; then
    _list_transfer_from_kanban
    _view_mode="list"
  else
    _list_transfer_to_kanban
    _view_mode="kanban"
  fi
}

_state_file_mtime() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  stat -f '%m' "$path" 2>/dev/null || stat -c '%Y' "$path" 2>/dev/null
}

_dash_poll_external_state() {
  local state_mtime=""
  state_mtime=$(_state_file_mtime "$GLOBAL_STATE" 2>/dev/null || true)
  if [[ -n "$state_mtime" ]]; then
    if [[ "$state_mtime" != "${_state_mtime:-}" ]]; then
      _state_mtime="$state_mtime"
      _dash_mark_snapshot_dirty
    fi
  else
    _state_mtime=""
  fi

  local pane_count="1"
  pane_count=$(_tmux_dashboard_pane_count 2>/dev/null || echo "1")
  if [[ "$pane_count" == <-> ]] && (( pane_count > 1 )); then
    if _tmux_dashboard_rehome_extra_panes; then
      pane_count=$(_tmux_dashboard_pane_count 2>/dev/null || echo "1")
      _dash_mark_dock_dirty
      _dash_mark_layout_dirty
      _dash_mark_list_dirty
    fi
  fi
  if [[ "$pane_count" != "${_dash_last_pane_count:--1}" ]]; then
    if [[ "${_dash_last_pane_count:--1}" != "-1" ]]; then
      _dash_mark_dock_dirty
      _dash_mark_layout_dirty
      _dash_mark_list_dirty
    fi
    _dash_last_pane_count="$pane_count"
  fi

  local active_pane=""
  active_pane=$(_tmux_dashboard_active_pane_index 2>/dev/null || true)
  if [[ -n "$active_pane" && "$active_pane" != "${_dash_last_active_pane:-}" ]]; then
    if [[ "$active_pane" == "0" ]]; then
      _full_redraw=1
    fi
    _dash_last_active_pane="$active_pane"
  fi

  local -i window_active=0
  _tmux_dashboard_window_active && window_active=1
  _dash_last_window_active=$window_active

  if [[ "$pane_count" == "1" && $window_active -eq 1 ]]; then
    if [[ -n "${_dock_data:-}" ]] || _tmux_dashboard_has_dock; then
      _dash_mark_dock_dirty
    fi
  fi
}

# The actual dashboard rendering loop (run inside tmux window)
cmd__dash_loop() {
  set +x  # Disable any inherited trace mode
  set +e  # Prevent unguarded commands from killing the TUI loop
  set +u  # Allow unset assoc-array keys (collapsed state, scroll offsets, etc.)
  setopt TYPESET_SILENT 2>/dev/null

  zmodload zsh/datetime 2>/dev/null || true

  # Navigation state
  local filter_mode="all"  # "all" or a repo name
  local -i filter_idx=0    # 0=all, 1+=specific repo
  local nav_mode="repo"    # "repo" or "card"
  local -i cur_repo_idx=0  # selected repo in all view
  local -i _viewport_start=0  # first expanded repo in sliding window
  local -i cur_col=0       # selected column (0-4)

  # Cron navigation state
  local -i cron_row_selected=0  # 1 when cron row is focused
  local -i cur_cron_col=0       # selected cron column (0-2)
  typeset -A cur_cron_card_row  # col -> row index within cron cards
  local _last_archive_check=0   # epoch of last stale-run cleanup

  # Per-repo-per-column card cursor: keyed by "reponame:col" -> row index
  typeset -A cur_card_row
  # Per-repo scroll offset for card viewport
  typeset -A _scroll_top
  # Per-repo collapsed state for accordion (1=collapsed, unset=expanded)
  typeset -A _repo_collapsed

  # ── List mode state ──
  local _view_mode="list"          # "kanban" or "list"
  local -i _split_active=0        # 1 when sidebar+session split is open
  local -i _show_done=0           # 1 when done tasks visible in list mode
  local -i _list_cursor=0         # index into _list_items[]
  local -i _list_scroll_top=0     # first visible content-line in viewport
  local -a _list_items=()         # flat ordered array: "group:repo", "task:t-001", etc.
  local -i _list_needs_rebuild=1  # 1 when flat list ordering must be rebuilt
  local _split_task_id=""          # task ID (or cron ID) in right pane
  local -i _split_is_cron=0       # 1 when split pane shows a cron session
  local _list_follow_id=""         # task ID to follow after re-sort
  local _list_follow_type="task"   # "task" or "cron" prefix for follow target
  typeset -A _list_group_collapsed # group_name -> 1 if collapsed
  local -i _list_scrollbar_vh=0    # set by _render_list_full for deferred scrollbar
  local -i _list_scrollbar_total=0
  local -i _sidebar_border_vh=0    # set by _render_list_sidebar for deferred border
  local -i _sidebar_border_w=0

  # Declare snapshot arrays (persist across loop, modified by _snapshot_tasks via dynamic scope)
  typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at
  typeset -A _repo_paths _repo_types _repo_stale _repo_task_count
  typeset -A _repo_cols _repo_col_cnt
  local -a _repo_names
  local _total_task_count=0 _active_count=0 _review_count=0
  local _tid=""  # scratch variable for _get_selected_id / _get_repo_task_at

  # Cron snapshot arrays
  typeset -A _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
  typeset -A _cron_col_ids _cron_col_cnt
  local _has_cron_data=false
  local _last_runtime_gc_check=0
  local -i _snapshot_dirty=1 _dock_dirty=1 _layout_dirty=1 _full_redraw=1
  local _state_mtime=""
  local -i _dash_last_pane_count=-1
  local _dash_last_active_pane=""
  local -i _dash_last_window_active=-1
  local -i cols=0 rows=0 col_width=0 card_inner=0
  local _border_card="" _border_full="" _dock_data=""

  _dash_mark_snapshot_dirty() {
    _snapshot_dirty=1
    _list_needs_rebuild=1
    _full_redraw=1
  }

  _dash_mark_list_dirty() {
    _list_needs_rebuild=1
    _full_redraw=1
  }

  _dash_mark_dock_dirty() {
    _dock_dirty=1
    _full_redraw=1
  }

  _dash_mark_layout_dirty() {
    _layout_dirty=1
    _full_redraw=1
  }

  # Trap to restore terminal on exit
  cleanup_dash() {
    if [[ ${_split_active:-0} -eq 1 ]]; then
      _split_close keep
    fi
    cursor_show
    stty echo 2>/dev/null
    printf '\033[?1049l'
  }
  trap cleanup_dash EXIT INT TERM

  printf '\033[?1049h'  # Enter alternate screen
  tui_reset_viewport
  cursor_hide
  stty -echo 2>/dev/null

  # Drain any pending terminal responses
  while read -rsk1 -t 0.05 _discard 2>/dev/null; do :; done

  _reconcile_task_runtime true false
  _last_runtime_gc_check=$(date +%s)
  _dock_data=$(_tmux_dashboard_read_dock 2>/dev/null || true)
  _split_sync_state "$_dock_data" || true
  if [[ -n "$_dock_data" ]]; then
    _view_mode="list"
  fi
  _state_mtime=$(_state_file_mtime "$GLOBAL_STATE" 2>/dev/null || true)
  _dash_last_pane_count=$(_tmux_dashboard_pane_count 2>/dev/null || echo "1")
  _dash_last_active_pane=$(_tmux_dashboard_active_pane_index 2>/dev/null || true)
  if _tmux_dashboard_window_active; then
    _dash_last_window_active=1
  else
    _dash_last_window_active=0
  fi

  while true; do
    local _t0=""
    [[ "${CLOARD_DEBUG:-}" == "1" ]] && _t0=${EPOCHREALTIME:-}
    local _perf_snapshot_ms=0.0 _perf_dock_ms=0.0 _perf_list_ms=0.0 _perf_render_ms=0.0 _perf_input_ms=0.0
    local _perf_phase_t0=""
    local _i

    _dash_poll_external_state

    local _term_cols _term_rows _pane_size
    _pane_size=$(_tmux_dashboard_primary_pane_size 2>/dev/null || true)
    if [[ -n "$_pane_size" ]]; then
      IFS=' ' read -r _term_cols _term_rows <<< "$_pane_size"
    else
      _term_cols=$(tput cols 2>/dev/null || echo "${cols:-0}")
      _term_rows=$(tput lines 2>/dev/null || echo "${rows:-0}")
    fi
    if [[ "$_term_cols" != "$cols" || "$_term_rows" != "$rows" ]]; then
      _layout_dirty=1
    fi

    if [[ $_layout_dirty -eq 1 ]]; then
      cols=$_term_cols
      rows=$_term_rows
      col_width=$(( (cols - 2) / 4 ))
      card_inner=$(( col_width - 4 ))
      _border_card=""
      _border_full=""
      for (( _i=0; _i<card_inner; _i++ )); do _border_card+="─"; done
      for (( _i=0; _i<cols; _i++ )); do _border_full+="─"; done
      _layout_dirty=0
    fi

    local _gc_now_epoch
    _gc_now_epoch=$(date +%s)
    if [[ $((_gc_now_epoch - _last_runtime_gc_check)) -ge TASK_RUNTIME_GC_INTERVAL_SECS ]]; then
      _reconcile_task_runtime true false dashboard
      _last_runtime_gc_check=$_gc_now_epoch
      if [[ "$_gc_actions" -gt 0 ]]; then
        _dash_mark_snapshot_dirty
        _dash_mark_dock_dirty
        _dash_mark_layout_dirty
        _dash_mark_list_dirty
      fi
    fi

    local -i _has_dock=0

    if [[ $_snapshot_dirty -eq 1 ]]; then
      [[ -n "$_t0" ]] && _perf_phase_t0=${EPOCHREALTIME:-}
      _snapshot_tasks
      if [[ -n "$_perf_phase_t0" ]] && [[ -n "${EPOCHREALTIME:-}" ]]; then
        _perf_snapshot_ms=$((_perf_snapshot_ms + (EPOCHREALTIME - _perf_phase_t0) * 1000))
      fi
      _snapshot_dirty=0
      _list_needs_rebuild=1
    fi

    if [[ $_dock_dirty -eq 1 ]]; then
      [[ -n "$_t0" ]] && _perf_phase_t0=${EPOCHREALTIME:-}
      _dock_data=$(_tmux_dashboard_read_dock 2>/dev/null || true)
      [[ -n "$_dock_data" ]] && _has_dock=1
      _split_sync_state "$_dock_data" || true
      if [[ $_has_dock -eq 1 ]]; then
        _view_mode="list"
        if _dash_restore_dock_if_needed "$_dock_data"; then
            _snapshot_dirty=1
            _list_needs_rebuild=1
            _dock_data=$(_tmux_dashboard_read_dock 2>/dev/null || true)
            [[ -n "$_dock_data" ]] && _has_dock=1 || _has_dock=0
        fi
      fi
      if [[ -n "$_perf_phase_t0" ]] && [[ -n "${EPOCHREALTIME:-}" ]]; then
        _perf_dock_ms=$((_perf_dock_ms + (EPOCHREALTIME - _perf_phase_t0) * 1000))
      fi
      _dock_dirty=0
    else
      [[ -n "$_dock_data" ]] && _has_dock=1
    fi

    if [[ $_snapshot_dirty -eq 1 ]]; then
      [[ -n "$_t0" ]] && _perf_phase_t0=${EPOCHREALTIME:-}
      _snapshot_tasks
      if [[ -n "$_perf_phase_t0" ]] && [[ -n "${EPOCHREALTIME:-}" ]]; then
        _perf_snapshot_ms=$((_perf_snapshot_ms + (EPOCHREALTIME - _perf_phase_t0) * 1000))
      fi
      _snapshot_dirty=0
      _list_needs_rebuild=1
    fi

    if [[ "$_view_mode" == "list" && $_list_needs_rebuild -eq 1 ]]; then
      [[ -n "$_t0" ]] && _perf_phase_t0=${EPOCHREALTIME:-}
      _list_build_items
      if [[ -n "$_perf_phase_t0" ]] && [[ -n "${EPOCHREALTIME:-}" ]]; then
        _perf_list_ms=$((_perf_list_ms + (EPOCHREALTIME - _perf_phase_t0) * 1000))
      fi
      _list_needs_rebuild=0
    fi

    # Clamp list cursor when list mode is active
    if [[ "$_view_mode" == "list" ]]; then
      if [[ ${#_list_items[@]} -gt 0 ]]; then
        [[ $_list_cursor -ge ${#_list_items[@]} ]] && _list_cursor=$((${#_list_items[@]} - 1))
        [[ $_list_cursor -lt 0 ]] && _list_cursor=0
      else
        _list_cursor=0
      fi
    fi

    # Clamp navigation indices
    if [[ ${#_repo_names[@]} -gt 0 ]]; then
      [[ $cur_repo_idx -ge ${#_repo_names[@]} ]] && cur_repo_idx=$((${#_repo_names[@]} - 1))
    else
      cur_repo_idx=0
    fi

    # Clamp card cursors for all repos
    for rn in "${_repo_names[@]}"; do
      for ci in {0..3}; do
        local ckey="${rn}:${ci}"
        local ccnt="${_repo_col_cnt[$ckey]:-0}"
        local crow="${cur_card_row[$ckey]:-0}"
        if [[ $crow -ge $ccnt ]] && [[ $ccnt -gt 0 ]]; then
          cur_card_row[$ckey]=$((ccnt - 1))
        elif [[ $ccnt -eq 0 ]]; then
          cur_card_row[$ckey]=0
        fi
      done
    done

    # Validate filter_mode still exists
    if [[ "$filter_mode" != "all" ]]; then
      local _filter_valid=false
      for rn in "${_repo_names[@]}"; do
        [[ "$rn" == "$filter_mode" ]] && _filter_valid=true
      done
      if ! $_filter_valid; then
        filter_mode="all"
        filter_idx=0
        nav_mode="repo"
      fi
    fi

    # Compute the exact footer string and reserve the matching wrapped height.
    local _footer_text=""
    local -i _footer_lines=1
    _footer_select_layout

    # Viewport height available for content (below status bar, above footer)
    local _viewport_height=$((rows - 1 - _footer_lines))
    [[ $_viewport_height -lt 1 ]] && _viewport_height=1

    [[ -n "$_t0" ]] && _perf_phase_t0=${EPOCHREALTIME:-}

    # Begin frame buffer
    local _frame=""

    # Title bar
    _render_status_bar

    if [[ ${#_repo_names[@]} -eq 0 ]]; then
      # No repos registered
      _frame+=$'\n'
      _frame+="  ${C_DIM}No repos registered. Run: cloard-board repo add <path>${C_RESET}"$'\n'
    elif [[ "$_view_mode" == "list" ]]; then
      # ── List mode rendering ──
      if [[ $_split_active -eq 1 ]]; then
        _render_list_sidebar
      else
        _render_list_full
      fi
    elif [[ "$filter_mode" == "all" ]]; then
      # ── All-repos view (compact cards with accordion) ──
      local total_repos=${#_repo_names[@]}
      local MAX_EXPANDED=4
      local cron_reserve=0
      if $_has_cron_data; then
        local _cr_max=0
        for _ci in {0..3}; do
          local _cr_cnt="${_cron_col_cnt[__cron:${_ci}]:-0}"
          [[ $_cr_cnt -gt $_cr_max ]] && _cr_max=$_cr_cnt
        done
        local _cr_vis=$((_cr_max < 3 ? _cr_max : 3))
        [[ $_cr_vis -lt 1 ]] && _cr_vis=1
        cron_reserve=$((_cr_vis * 5 + 3))  # cards + header + col headers + gap
      fi

      # Auto-initialize: collapse repos beyond MAX_EXPANDED on first render
      local _init_exp=0
      for rn in "${_repo_names[@]}"; do
        if [[ -z "${_repo_collapsed[$rn]+x}" ]]; then
          [[ $_init_exp -ge $MAX_EXPANDED ]] && _repo_collapsed[$rn]=1
        fi
        [[ "${_repo_collapsed[$rn]:-}" != "1" ]] && _init_exp=$((_init_exp + 1))
      done

      # Count expanded/collapsed repos
      local expanded_count=0 collapsed_count=0
      for rn in "${_repo_names[@]}"; do
        if [[ "${_repo_collapsed[$rn]:-}" == "1" ]]; then
          collapsed_count=$((collapsed_count + 1))
        else
          expanded_count=$((expanded_count + 1))
        fi
      done
      [[ $expanded_count -lt 1 ]] && expanded_count=1

      # Calculate max cards per expanded repo (compact: 3 lines/card)
      local collapsed_lines=$collapsed_count
      local available=$((rows - 2 - collapsed_lines - cron_reserve))
      local per_expanded=$(( available / expanded_count ))
      local max_cards_global=$(( (per_expanded - 2) / 3 ))
      [[ $max_cards_global -lt 1 ]] && max_cards_global=1

      local repo_idx=0
      for rname in "${_repo_names[@]}"; do
        local is_sel_repo=false
        [[ $repo_idx -eq $cur_repo_idx ]] && is_sel_repo=true
        local is_expanded=false
        [[ "${_repo_collapsed[$rname]:-}" != "1" ]] && is_expanded=true

        local tcnt="${_repo_task_count[$rname]:-0}"
        local stale_indicator=""
        [[ -n "${_repo_stale[$rname]:-}" ]] && stale_indicator=" ${C_RED}(path not found)${C_RESET}"

        if ! $is_expanded; then
          # ── Collapsed repo: header only ──
          if $is_sel_repo && [[ "$nav_mode" == "repo" ]]; then
            local _ch="> [${rname}] (${tcnt} tasks)"
            _frame+="${C_BOLD}${C_BG_BLUE}${C_WHITE}${(r:${cols}:)_ch}${C_RESET}"
          else
            local _ch="  [${rname}] (${tcnt} tasks)"
            _frame+="${C_DIM}${(r:${cols}:)_ch}${C_RESET}"
          fi
          _frame+=$'\n'
          repo_idx=$((repo_idx + 1))
          continue
        fi

        # ── Expanded repo ──
        # Repo header
        local repo_hdr="[${rname}]${stale_indicator} (${tcnt} tasks)"
        if $is_sel_repo && [[ "$nav_mode" == "repo" ]]; then
          local _rh="> ${repo_hdr}"
          _frame+="${C_BOLD}${C_BG_BLUE}${C_WHITE}${(r:${cols}:)_rh}${C_RESET}"
        else
          local _rh="  ${repo_hdr}"
          _frame+="${C_BOLD}${(r:${cols}:)_rh}${C_RESET}"
        fi
        _frame+=$'\n'

        # Skip card rendering for empty non-selected repos
        if [[ $tcnt -eq 0 ]] && ! $is_sel_repo; then
          repo_idx=$((repo_idx + 1))
          continue
        fi

        # Column headers
        local header_line=""
        for i in {0..3}; do
          local cc=$(col_color "$i")
          local cname="${COL_NAMES[$i]}"
          local ccnt="${_repo_col_cnt[${rname}:${i}]:-0}"
          local hdr=$(printf "%s (%d)" "$cname" "$ccnt")
          hdr=$(trunc "$hdr" "$col_width")
          local hdr_sel=""
          if $is_sel_repo && [[ $i -eq $cur_col ]]; then
            hdr_sel="${C_BOLD}"
          fi
          header_line+=$(printf "${hdr_sel}${cc}%-${col_width}s${C_RESET}" "$hdr")
        done
        _frame+="$header_line"$'\n'

        # Cards: compute actual max and visible window with scrolling
        local actual_max=0
        for i in {0..3}; do
          local cnt="${_repo_col_cnt[${rname}:${i}]:-0}"
          [[ $cnt -gt $actual_max ]] && actual_max=$cnt
        done
        local visible_cards=$max_cards_global
        [[ $visible_cards -gt $actual_max ]] && visible_cards=$actual_max

        # Compute scroll offset for selected repo in card mode
        local scroll_off="${_scroll_top[$rname]:-0}"
        if $is_sel_repo && [[ "$nav_mode" == "card" ]]; then
          local focused_row="${cur_card_row[${rname}:${cur_col}]:-0}"
          if [[ $focused_row -ge $((scroll_off + visible_cards)) ]]; then
            scroll_off=$((focused_row - visible_cards + 1))
          fi
          if [[ $focused_row -lt $scroll_off ]]; then
            scroll_off=$focused_row
          fi
          _scroll_top[$rname]=$scroll_off
        fi

        if [[ $visible_cards -gt 0 ]]; then
          # Scroll-up indicator
          if [[ $scroll_off -gt 0 ]]; then
            _frame+="  ${C_DIM}${TUI_GLYPH_SCROLL_UP} ${scroll_off} more above${C_RESET}"$'\n'
          fi

          # Render compact 3-line bordered cards
          local _rseq=()
          _rseq=($(seq $scroll_off $((scroll_off + visible_cards - 1))))
          for row_idx in "${_rseq[@]}"; do
            for line_no in {0..2}; do
              local output=""
              for col_idx in {0..3}; do
                local cc=$(col_color "$col_idx")
                _get_repo_task_at "$rname" "$col_idx" "$row_idx"
                local task_id="$_tid"

                if [[ -z "$task_id" ]]; then
                  output+=$(printf '%-*s' "$col_width" "")
                else
                  # Paused override
                  [[ $col_idx -eq 0 && "${_task_status[$task_id]}" == "paused" ]] && cc="$C_CYAN"

                  local is_selected=false
                  if $is_sel_repo && [[ "$nav_mode" == "card" ]]; then
                    local crow="${cur_card_row[${rname}:${col_idx}]:-0}"
                    [[ $col_idx -eq $cur_col && $crow -eq $row_idx ]] && is_selected=true
                  fi

                  local title="${_task_title[$task_id]}"
                  local pr="${_task_pr[$task_id]}"
                  local pr_short=""
                  [[ -n "$pr" ]] && pr_short=$(echo "$pr" | grep -oE '#[0-9]+' 2>/dev/null || echo "PR")

                  local sel_prefix=" "
                  local sel_color=""
                  if $is_selected; then
                    sel_prefix=">"
                    sel_color="${C_BOLD}${C_BG_BLUE}${C_WHITE}"
                  fi

                  local cell=""
                  case $line_no in
                    0)
                      # Top border with embedded ID: ┌ t-001 ─────┐
                      local id_str=$(trunc "$task_id" $((card_inner - 2)))
                      local id_fill_len=$((card_inner - ${#id_str} - 2))
                      [[ $id_fill_len -lt 0 ]] && id_fill_len=0
                      local id_fill="${_border_card:0:$id_fill_len}"
                      if $is_selected; then
                        cell=$(printf "${sel_color}%s┌ %s %s┐${C_RESET}" "$sel_prefix" "$id_str" "$id_fill")
                      else
                        cell=$(printf "%s${cc}┌ ${C_BOLD}%s${C_RESET}${cc} %s┐${C_RESET}" " " "$id_str" "$id_fill")
                      fi
                      ;;
                    1)
                      # Title row: │ Fix login bug       │
                      local title_str=$(trunc "$title" $((card_inner - 1)))
                      if $is_selected; then
                        cell=$(printf "${sel_color}${sel_prefix}│%-*s│${C_RESET}" "$card_inner" " ${title_str}")
                      else
                        cell=$(printf "${cc} │%-*s│${C_RESET}" "$card_inner" " ${title_str}")
                      fi
                      ;;
                    2)
                      # Bottom border with status: └ * working ──┘
                      local cstatus="${_task_claude[$task_id]}"
                      local extra="" extra_color=""
                      [[ "$cstatus" == "working" ]] && { extra="${TUI_GLYPH_WORKING} working"; extra_color="${C_GREEN}"; }
                      # waiting status hidden (too noisy)
                      [[ -n "$pr_short" ]] && { [[ -n "$extra" ]] && extra="${extra} ${pr_short}" || extra="$pr_short"; }
                      local tstatus="${_task_status[$task_id]}"
                      if [[ "$tstatus" != "pending" ]]; then
                        local tstatus_at="${_task_activity_at[$task_id]:-${_task_status_at[$task_id]:-}}"
                        if [[ -n "$tstatus_at" ]]; then
                          _time_ago "$tstatus_at"
                          [[ -n "$_tago" ]] && { [[ -n "$extra" ]] && extra="${extra} ${_tago}" || extra="$_tago"; }
                        fi
                      fi
                      if [[ -n "$extra" ]]; then
                        extra=$(trunc "$extra" $((card_inner - 2)))
                        local st_fill_len=$((card_inner - ${#extra} - 2))
                        [[ $st_fill_len -lt 0 ]] && st_fill_len=0
                        local st_fill="${_border_card:0:$st_fill_len}"
                        if $is_selected; then
                          cell=$(printf "${sel_color}%s└ %s %s┘${C_RESET}" "$sel_prefix" "$extra" "$st_fill")
                        elif [[ -n "$extra_color" ]]; then
                          cell=$(printf "%s${cc}└ ${extra_color}%s${C_RESET}${cc} %s┘${C_RESET}" " " "$extra" "$st_fill")
                        else
                          cell=$(printf "%s${cc}${C_DIM}└ %s %s┘${C_RESET}" " " "$extra" "$st_fill")
                        fi
                      else
                        if $is_selected; then
                          cell=$(printf "${sel_color}%s└%s┘${C_RESET}" "$sel_prefix" "$_border_card")
                        else
                          cell=$(printf "${cc} └%s┘${C_RESET}" "$_border_card")
                        fi
                      fi
                      ;;
                  esac
                  output+="$cell"
                  local cell_visual_len=$((card_inner + 4))
                  local pad=$(( col_width - cell_visual_len ))
                  [[ $pad -gt 0 ]] && output+=$(printf '%*s' "$pad" "")
                fi
              done
              _frame+="$output"$'\n'
            done
          done

          # Scroll-down indicator
          local below=$((actual_max - scroll_off - visible_cards))
          if [[ $below -gt 0 ]]; then
            _frame+="  ${C_DIM}${TUI_GLYPH_SCROLL_DOWN} ${below} more below${C_RESET}"$'\n'
          fi
        fi

        repo_idx=$((repo_idx + 1))
      done

    else
      # ── Filtered single-repo view ──
      local rname="$filter_mode"
      local filt_cron_reserve=0
      if $_has_cron_data; then
        local _fcr_max=0
        for _ci in {0..3}; do
          local _fcr_cnt="${_cron_col_cnt[__cron:${_ci}]:-0}"
          [[ $_fcr_cnt -gt $_fcr_max ]] && _fcr_max=$_fcr_cnt
        done
        local _fcr_vis=$((_fcr_max < 3 ? _fcr_max : 3))
        [[ $_fcr_vis -lt 1 ]] && _fcr_vis=1
        filt_cron_reserve=$((_fcr_vis * 5 + 3))
      fi
      local max_visible_rows=$(( (rows - 5 - filt_cron_reserve) / 5 ))
      [[ $max_visible_rows -lt 1 ]] && max_visible_rows=1

      # Column headers
      local header_line=""
      for i in {0..3}; do
        local cc=$(col_color "$i")
        local cname="${COL_NAMES[$i]}"
        local ccnt="${_repo_col_cnt[${rname}:${i}]:-0}"
        local selected=""
        [[ $i -eq $cur_col ]] && selected="${C_BOLD}"
        local hdr=$(printf "%s (%d)" "$cname" "$ccnt")
        hdr=$(trunc "$hdr" "$col_width")
        header_line+=$(printf "${selected}${cc}%-${col_width}s${C_RESET}" "$hdr")
      done
      _frame+="$header_line"$'\n'
      _frame+="$_border_full"$'\n'

      # Cards: compute actual max and visible window with scrolling
      local actual_max=0
      for i in {0..3}; do
        local cnt="${_repo_col_cnt[${rname}:${i}]:-0}"
        [[ $cnt -gt $actual_max ]] && actual_max=$cnt
      done
      local visible_cards=$max_visible_rows
      [[ $visible_cards -gt $actual_max ]] && visible_cards=$actual_max

      # Compute scroll offset
      local scroll_off="${_scroll_top[$rname]:-0}"
      local focused_row="${cur_card_row[${rname}:${cur_col}]:-0}"
      if [[ $focused_row -ge $((scroll_off + visible_cards)) ]]; then
        scroll_off=$((focused_row - visible_cards + 1))
      fi
      if [[ $focused_row -lt $scroll_off ]]; then
        scroll_off=$focused_row
      fi
      _scroll_top[$rname]=$scroll_off

      if [[ $visible_cards -gt 0 ]]; then
        # Scroll-up indicator
        if [[ $scroll_off -gt 0 ]]; then
          _frame+="  ${C_DIM}${TUI_GLYPH_SCROLL_UP} ${scroll_off} more above${C_RESET}"$'\n'
        fi

        local _rseq=()
        _rseq=($(seq $scroll_off $((scroll_off + visible_cards - 1))))
        for row_idx in "${_rseq[@]}"; do
          for line_no in {0..4}; do
            local output=""
            for col_idx in {0..3}; do
              local cc=$(col_color "$col_idx")
              _get_repo_task_at "$rname" "$col_idx" "$row_idx"
              local task_id="$_tid"

              if [[ -z "$task_id" ]]; then
                output+=$(printf '%-*s' "$col_width" "")
              else
                [[ $col_idx -eq 0 && "${_task_status[$task_id]}" == "paused" ]] && cc="$C_CYAN"

                local is_selected=false
                local crow="${cur_card_row[${rname}:${col_idx}]:-0}"
                [[ $col_idx -eq $cur_col && $crow -eq $row_idx ]] && is_selected=true

                local title="${_task_title[$task_id]}"
                local pr="${_task_pr[$task_id]}"
                local pr_short=""
                [[ -n "$pr" ]] && pr_short=$(echo "$pr" | grep -oE '#[0-9]+' 2>/dev/null || echo "PR")

                local sel_prefix=" "
                local sel_color=""
                if $is_selected; then
                  sel_prefix=">"
                  sel_color="${C_BOLD}${C_BG_BLUE}${C_WHITE}"
                fi

                local cell=""
                case $line_no in
                  0)
                    if $is_selected; then
                      cell=$(printf "${sel_color}${sel_prefix}┌%s┐${C_RESET}" "$_border_card")
                    else
                      cell=$(printf "${cc} ┌%s┐${C_RESET}" "$_border_card")
                    fi
                    ;;
                  1)
                    local id_str=$(trunc "$task_id" $((card_inner - 1)))
                    if $is_selected; then
                      cell=$(printf "${sel_color} │%-*s│${C_RESET}" "$card_inner" " ${id_str}")
                    else
                      cell=$(printf "${cc} │${C_BOLD}%-*s${C_RESET}${cc}│${C_RESET}" "$card_inner" " ${id_str}")
                    fi
                    ;;
                  2)
                    local title_str=$(trunc "$title" $((card_inner - 1)))
                    if $is_selected; then
                      cell=$(printf "${sel_color} │%-*s│${C_RESET}" "$card_inner" " ${title_str}")
                    else
                      cell=$(printf "${cc} │%-*s│${C_RESET}" "$card_inner" " ${title_str}")
                    fi
                    ;;
                  3)
                    local cstatus="${_task_claude[$task_id]}"
                    local extra="" extra_color=""
                    [[ "$cstatus" == "working" ]] && { extra="${TUI_GLYPH_WORKING} working"; extra_color="${C_GREEN}"; }
                    [[ "$cstatus" == "waiting" ]] && { extra="${TUI_GLYPH_WAITING} waiting"; extra_color="${C_YELLOW}"; }
                    [[ -n "$pr_short" ]] && { [[ -n "$extra" ]] && extra="${extra} ${pr_short}" || extra="$pr_short"; }
                    local tstatus="${_task_status[$task_id]}"
                    if [[ "$tstatus" != "pending" ]]; then
                      local tstatus_at="${_task_activity_at[$task_id]:-${_task_status_at[$task_id]:-}}"
                      if [[ -n "$tstatus_at" ]]; then
                        _time_ago "$tstatus_at"
                        [[ -n "$_tago" ]] && { [[ -n "$extra" ]] && extra="${extra} ${_tago}" || extra="$_tago"; }
                      fi
                    fi
                    extra=$(trunc "$extra" $((card_inner - 1)))
                    if $is_selected; then
                      cell=$(printf "${sel_color} │%-*s│${C_RESET}" "$card_inner" " ${extra}")
                    elif [[ -n "$extra_color" ]]; then
                      cell=$(printf "${cc} │${extra_color}%-*s${C_RESET}${cc}│${C_RESET}" "$card_inner" " ${extra}")
                    else
                      cell=$(printf "${cc}${C_DIM} │%-*s│${C_RESET}" "$card_inner" " ${extra}")
                    fi
                    ;;
                  4)
                    if $is_selected; then
                      cell=$(printf "${sel_color} └%s┘${C_RESET}" "$_border_card")
                    else
                      cell=$(printf "${cc} └%s┘${C_RESET}" "$_border_card")
                    fi
                    ;;
                esac
                output+="$cell"
                local cell_visual_len=$((card_inner + 4))
                local pad=$(( col_width - cell_visual_len ))
                [[ $pad -gt 0 ]] && output+=$(printf '%*s' "$pad" "")
              fi
            done
            _frame+="$output"$'\n'
          done
        done

        # Scroll-down indicator
        local below=$((actual_max - scroll_off - visible_cards))
        if [[ $below -gt 0 ]]; then
          _frame+="  ${C_DIM}${TUI_GLYPH_SCROLL_DOWN} ${below} more below${C_RESET}"$'\n'
        fi
      fi
    fi

    # ── Cron row (kanban mode only; list mode handles cron in _list_items) ──
    if [[ "$_view_mode" == "kanban" ]] && $_has_cron_data; then
      _render_cron_row
    fi

    # Clip frame to terminal height (header always visible; reserve footer lines)
    local _max_lines=$((rows - _footer_lines))
    local -a _flines
    _flines=("${(@f)_frame}")
    if [[ ${#_flines[@]} -gt $_max_lines ]]; then
      _flines=("${_flines[@]:0:$_max_lines}")
      _frame="${(pj:\n:)_flines[@]}"$'\n'
    fi

    # Output frame (CSI 3 J clears tmux pane scrollback inline to prevent stale frames on scroll-up)
    printf '\033[r\033[?6l\033[3J\033[H%s\033[J' "$_frame"

    # Deferred scrollbar (list mode, rendered after frame to use move_to positioning)
    if [[ "$_view_mode" == "list" && $_list_scrollbar_vh -gt 0 ]]; then
      _render_scrollbar_track "$_list_scrollbar_vh" "$_list_scrollbar_total"
      _list_scrollbar_vh=0
      _list_scrollbar_total=0
    fi

    # Deferred sidebar border (split mode, painted over the frame like the scrollbar)
    if [[ $_sidebar_border_vh -gt 0 ]]; then
      _render_sidebar_border "$_sidebar_border_vh" "$_sidebar_border_w"
      _sidebar_border_vh=0
      _sidebar_border_w=0
    fi

    # Footer
    _render_footer

    if [[ -n "$_perf_phase_t0" ]] && [[ -n "${EPOCHREALTIME:-}" ]]; then
      _perf_render_ms=$((_perf_render_ms + (EPOCHREALTIME - _perf_phase_t0) * 1000))
    fi

    # Read key with timeout
    local key=""
    read -rsk1 -t "$DASH_REFRESH" key 2>/dev/null || true

    # Handle escape sequences
    [[ -n "$_t0" ]] && _perf_phase_t0=${EPOCHREALTIME:-}
    if [[ "$key" == $'\e' ]]; then
      local seq=""
      read -rsk2 -t "$DASH_ESC_READ_TIMEOUT" seq 2>/dev/null || true
      case "$seq" in
        '[A') key='k' ;;     # up
        '[B') key='j' ;;     # down
        '[C') key='l' ;;     # right
        '[D') key='h' ;;     # left
        '[Z') key='SHIFT_TAB' ;;  # shift-tab
        *)    key='ESC' ;;   # plain Esc
      esac
    fi
    if [[ -n "$_perf_phase_t0" ]] && [[ -n "${EPOCHREALTIME:-}" ]]; then
      _perf_input_ms=$((_perf_input_ms + (EPOCHREALTIME - _perf_phase_t0) * 1000))
    fi

    # Debug timing
    if [[ -n "${_t0:-}" ]]; then
      local _phase_total=$((_perf_snapshot_ms + _perf_dock_ms + _perf_list_ms + _perf_render_ms + _perf_input_ms))
      printf '%s frame: %.1fms snapshot=%.1fms dock_sync=%.1fms list_build=%.1fms render=%.1fms input_parse=%.1fms\n' \
        "$(date +%T)" "$_phase_total" "$_perf_snapshot_ms" "$_perf_dock_ms" "$_perf_list_ms" "$_perf_render_ms" "$_perf_input_ms" >> /tmp/cloard-perf.log
    fi

    local _prev_split_active="$_split_active"
    local _prev_split_task_id="$_split_task_id"
    local _prev_split_is_cron="$_split_is_cron"
    local _prev_view_mode="$_view_mode"
    local _prev_show_done="$_show_done"
    local _prev_filter_mode="$filter_mode"

    case "$key" in
      h) # Left column
        if [[ $cron_row_selected -eq 1 ]]; then
          # Cron: constrained to cols 0-3
          local _ch_target=$((cur_cron_col - 1))
          while [[ $_ch_target -ge 0 ]]; do
            local _chcnt="${_cron_col_cnt[__cron:${_ch_target}]:-0}"
            [[ $_chcnt -gt 0 ]] && break
            _ch_target=$((_ch_target - 1))
          done
          [[ $_ch_target -ge 0 ]] && cur_cron_col=$_ch_target
        else
          local _h_target=$((cur_col - 1))
          local _h_repo=""
          if [[ "$filter_mode" != "all" ]]; then
            _h_repo="$filter_mode"
          elif [[ ${#_repo_names[@]} -gt 0 ]]; then
            _h_repo="${_repo_names[$cur_repo_idx]:-}"
          fi
          if [[ -n "$_h_repo" ]]; then
            while [[ $_h_target -ge 0 ]]; do
              local _hcnt="${_repo_col_cnt[${_h_repo}:${_h_target}]:-0}"
              [[ $_hcnt -gt 0 ]] && break
              _h_target=$((_h_target - 1))
            done
          fi
          [[ $_h_target -ge 0 ]] && cur_col=$_h_target
        fi
        ;;
      l) # Right column
        if [[ $cron_row_selected -eq 1 ]]; then
          local _cl_target=$((cur_cron_col + 1))
          while [[ $_cl_target -le 3 ]]; do
            local _clcnt="${_cron_col_cnt[__cron:${_cl_target}]:-0}"
            [[ $_clcnt -gt 0 ]] && break
            _cl_target=$((_cl_target + 1))
          done
          [[ $_cl_target -le 3 ]] && cur_cron_col=$_cl_target
        else
          local _l_target=$((cur_col + 1))
          local _l_repo=""
          if [[ "$filter_mode" != "all" ]]; then
            _l_repo="$filter_mode"
          elif [[ ${#_repo_names[@]} -gt 0 ]]; then
            _l_repo="${_repo_names[$cur_repo_idx]:-}"
          fi
          if [[ -n "$_l_repo" ]]; then
            while [[ $_l_target -le 3 ]]; do
              local _lcnt="${_repo_col_cnt[${_l_repo}:${_l_target}]:-0}"
              [[ $_lcnt -gt 0 ]] && break
              _l_target=$((_l_target + 1))
            done
          fi
          [[ $_l_target -le 3 ]] && cur_col=$_l_target
        fi
        ;;
      j) # Down
        if [[ $cron_row_selected -eq 1 ]]; then
          # Move down within cron cards
          local cck="__cron:${cur_cron_col}"
          local cmax=$(( ${_cron_col_cnt[$cck]:-0} - 1 ))
          local ccrow="${cur_cron_card_row[${cur_cron_col}]:-0}"
          if [[ $ccrow -lt $cmax ]]; then
            cur_cron_card_row[$cur_cron_col]=$((ccrow + 1))
          fi
        elif [[ "$filter_mode" == "all" && "$nav_mode" == "repo" ]]; then
          # Move between repo rows; cron is after the last repo
          if [[ $cur_repo_idx -lt $((${#_repo_names[@]} - 1)) ]]; then
            cur_repo_idx=$((cur_repo_idx + 1))
          elif $_has_cron_data; then
            cron_row_selected=1
            nav_mode="card"
          fi
        else
          # Move between cards within the active repo
          local active_repo
          if [[ "$filter_mode" != "all" ]]; then
            active_repo="$filter_mode"
          else
            active_repo="${_repo_names[$cur_repo_idx]:-}"
          fi
          if [[ -n "$active_repo" ]]; then
            local ckey="${active_repo}:${cur_col}"
            local max_idx=$(( ${_repo_col_cnt[$ckey]:-0} - 1 ))
            local crow="${cur_card_row[$ckey]:-0}"
            if [[ $crow -lt $max_idx ]]; then
              cur_card_row[$ckey]=$((crow + 1))
            elif [[ "$filter_mode" == "all" && $cur_repo_idx -lt $((${#_repo_names[@]} - 1)) ]]; then
              cur_repo_idx=$((cur_repo_idx + 1))
            elif [[ "$filter_mode" == "all" ]] && $_has_cron_data; then
              # Overflow to cron row
              cron_row_selected=1
              nav_mode="card"
            fi
          elif [[ "$filter_mode" == "all" && $cur_repo_idx -lt $((${#_repo_names[@]} - 1)) ]]; then
            cur_repo_idx=$((cur_repo_idx + 1))
          elif [[ "$filter_mode" == "all" ]] && $_has_cron_data; then
            cron_row_selected=1
            nav_mode="card"
          fi
        fi
        ;;
      k) # Up
        if [[ $cron_row_selected -eq 1 ]]; then
          local ccrow="${cur_cron_card_row[${cur_cron_col}]:-0}"
          if [[ $ccrow -gt 0 ]]; then
            cur_cron_card_row[$cur_cron_col]=$((ccrow - 1))
          else
            # Move back to last repo
            cron_row_selected=0
            if [[ ${#_repo_names[@]} -gt 0 ]]; then
              cur_repo_idx=$((${#_repo_names[@]} - 1))
              nav_mode="repo"
            fi
          fi
        elif [[ "$filter_mode" == "all" && "$nav_mode" == "repo" ]]; then
          [[ $cur_repo_idx -gt 0 ]] && cur_repo_idx=$((cur_repo_idx - 1))
        else
          local active_repo
          if [[ "$filter_mode" != "all" ]]; then
            active_repo="$filter_mode"
          else
            active_repo="${_repo_names[$cur_repo_idx]:-}"
          fi
          if [[ -n "$active_repo" ]]; then
            local ckey="${active_repo}:${cur_col}"
            local crow="${cur_card_row[$ckey]:-0}"
            if [[ $crow -gt 0 ]]; then
              cur_card_row[$ckey]=$((crow - 1))
            elif [[ "$filter_mode" == "all" && $cur_repo_idx -gt 0 ]]; then
              cur_repo_idx=$((cur_repo_idx - 1))
            fi
          elif [[ "$filter_mode" == "all" && $cur_repo_idx -gt 0 ]]; then
            cur_repo_idx=$((cur_repo_idx - 1))
          fi
        fi
        ;;
      '') ;; # Timeout: just refresh
      $'\t') # Tab: next filter (kanban only; list handles its own)
        if [[ "$_view_mode" == "kanban" ]]; then
          local total_filters=$(( ${#_repo_names[@]} + 1 ))
          filter_idx=$(( (filter_idx + 1) % total_filters ))
          if [[ $filter_idx -eq 0 ]]; then
            filter_mode="all"
            nav_mode="repo"
          else
            filter_mode="${_repo_names[$((filter_idx - 1))]}"
            nav_mode="card"
          fi
        fi
        ;;
      SHIFT_TAB) # Shift-Tab: previous filter (kanban only)
        if [[ "$_view_mode" == "kanban" ]]; then
          local total_filters=$(( ${#_repo_names[@]} + 1 ))
          filter_idx=$(( (filter_idx - 1 + total_filters) % total_filters ))
          if [[ $filter_idx -eq 0 ]]; then
            filter_mode="all"
            nav_mode="repo"
          else
            filter_mode="${_repo_names[$((filter_idx - 1))]}"
            nav_mode="card"
          fi
        fi
        ;;
      ESC) # Escape: zoom out to repo mode
        if [[ $cron_row_selected -eq 1 ]]; then
          cron_row_selected=0
          nav_mode="repo"
          if [[ ${#_repo_names[@]} -gt 0 ]]; then
            cur_repo_idx=$((${#_repo_names[@]} - 1))
          fi
        elif [[ "$filter_mode" == "all" && "$nav_mode" == "card" ]]; then
          nav_mode="repo"
        elif [[ "$filter_mode" == "all" && "$nav_mode" == "repo" ]]; then
          # Collapse the selected repo
          if [[ ${#_repo_names[@]} -gt 0 ]]; then
            local _esc_rname="${_repo_names[$cur_repo_idx]:-}"
            [[ -n "$_esc_rname" ]] && _repo_collapsed[$_esc_rname]=1
          fi
        fi
        ;;
      $'\n'|$'\r') # Enter (kanban only; list mode handles its own Enter below)
        if [[ "$_view_mode" != "kanban" ]]; then
          : # handled by list mode dispatch below
        elif [[ $cron_row_selected -eq 1 ]]; then
          # Handle cron row Enter
          if [[ "$nav_mode" == "repo" ]]; then
            nav_mode="card"
          elif _get_selected_cron_id; then
            local cron_item="$_tid"
            case $cur_cron_col in
              0)  # Scheduled: show job details
                cursor_show
                stty echo
                echo ""
                local jname="${_cron_jobs[$cron_item]:-}"
                local jsched="${_cron_job_schedule[$cron_item]:-}"
                local jenabled="${_cron_job_enabled[$cron_item]:-}"
                echo "${C_BOLD}Cron Job: ${cron_item}${C_RESET}"
                echo "  name: ${jname}"
                echo "  schedule: ${jsched}"
                echo "  enabled: ${jenabled}"
                echo ""
                echo "${C_DIM}Press any key to return...${C_RESET}"
                read -rsk1 2>/dev/null || true
                stty -echo
                cursor_hide
                ;;
              1|2|3)  # Active / Needs Review / Done: open in split pane via list mode
                [[ "${_split_active:-0}" == "1" ]] && _split_close keep
                _list_follow_id="$cron_item"
                _list_follow_type="cron"
                _view_mode="list"
                _list_transfer_from_kanban
                _split_open_cron "$cron_item"
                ;;
            esac
          fi
        elif [[ "$filter_mode" == "all" && "$nav_mode" == "repo" ]]; then
          if [[ $cron_row_selected -eq 0 && ${#_repo_names[@]} -gt 0 ]]; then
            local _toggle_rname="${_repo_names[$cur_repo_idx]:-}"
            if [[ -n "$_toggle_rname" ]]; then
              if [[ "${_repo_collapsed[$_toggle_rname]:-}" == "1" ]]; then
                # Collapsed repo: expand it
                unset '_repo_collapsed[$_toggle_rname]'
              else
                # Expanded repo: zoom into card mode
                nav_mode="card"
              fi
            fi
          fi
        elif _get_selected_id; then
          # Open/interact with selected task
          local sel_id="$_tid"
          local cur_status="${_task_status[$sel_id]}"
          local sel_repo="${_task_repo[$sel_id]}"
          local sel_rpath
          sel_rpath=$(repo_path "$sel_repo")

          # Check for stale repo
          if [[ -n "${_repo_stale[$sel_repo]:-}" ]]; then
            cursor_show
            stty echo
            echo ""
            echo "${C_RED}Repo path not found. Run: cloard-board repo update-path ${sel_repo} <new-path>${C_RESET}"
            sleep 2
            stty -echo
            cursor_hide
          else
            case "$cur_status" in
              pending)
                cursor_show
                stty echo
                local task_title="${_task_title[$sel_id]}"
                echo ""
                echo "${C_CYAN}Starting task '${sel_id}': ${task_title}${C_RESET}"
                printf "${C_CYAN}Prompt for Claude (or Enter to skip): ${C_RESET}"
                local task_prompt=""
                read -r task_prompt
                local dash_wt_mode="${_task_wtmode[$sel_id]}"
                local rtype="${_repo_types[$sel_repo]:-git}"
                if [[ "$rtype" == "dir" ]]; then
                  dash_wt_mode="none"
                elif [[ "$dash_wt_mode" != "none" ]]; then
                  printf "${C_CYAN}Use worktree? [Y/n]: ${C_RESET}"
                  local wt_choice=""
                  read -r wt_choice
                  if [[ "$wt_choice" =~ ^[nN]$ ]]; then
                    dash_wt_mode="none"
                    update_task_field "$sel_id" "worktree_mode" "none"
                    update_task_field_raw "$sel_id" "branch" "null"
                  fi
                fi
                stty -echo
                cursor_hide
                # Generate session ID for reliable resumption
                local dash_session_uid
                dash_session_uid=$(uuidgen | tr '[:upper:]' '[:lower:]')
                local dash_claude_cmd
                if [[ "$dash_wt_mode" == "none" ]]; then
                  dash_claude_cmd="claude --session-id ${dash_session_uid} --dangerously-skip-permissions"
                else
                  dash_claude_cmd="claude --worktree ${sel_id} --session-id ${dash_session_uid} --dangerously-skip-permissions"
                fi
                if [[ -n "$task_prompt" ]]; then
                  local escaped="${task_prompt//\'/\'\\\'\'}"
                  dash_claude_cmd="${dash_claude_cmd} '${escaped}'"
                fi
                _tmux_launch_claude "$sel_id" "$sel_rpath" "$dash_claude_cmd"
                set_task_status "$sel_id" "active"
                update_task_field "$sel_id" "started_at" "$(now_iso)"
                push_session_history "$sel_id" "$dash_session_uid"
                tmux_select_window "$sel_id"
                ;;
              paused)
                # Kill dead windows (Claude exited, bare zsh running)
                if _tmux_task_runtime_exists "$sel_id" && ! _tmux_task_runtime_live "$sel_id"; then
                  _tmux_close_task_runtime "$sel_id" || true
                fi
                if ! _tmux_task_runtime_exists "$sel_id"; then
                  local wt_mode_paused="${_task_wtmode[$sel_id]}"
                  local resume_cmd
                  resume_cmd=$(_build_claude_resume_cmd "$sel_id")
                  if [[ "$wt_mode_paused" == "none" ]]; then
                    _tmux_launch_claude "$sel_id" "$sel_rpath" "$resume_cmd"
                  else
                    local wt_p=$(find_worktree_path "$sel_id" "$sel_rpath")
                    [[ -n "$wt_p" ]] && _tmux_launch_claude "$sel_id" "$wt_p" "$resume_cmd"
                  fi
                fi
                set_task_status "$sel_id" "active"
                _tmux_focus_task_runtime "$sel_id" || true
                ;;
              active|needs_review)
                # Kill dead windows (Claude exited, bare zsh running)
                if _tmux_task_runtime_exists "$sel_id" && ! _tmux_task_runtime_live "$sel_id"; then
                  _tmux_close_task_runtime "$sel_id" || true
                fi
                if ! _tmux_task_runtime_exists "$sel_id"; then
                  local wt_mode_act="${_task_wtmode[$sel_id]}"
                  local resume_cmd
                  resume_cmd=$(_build_claude_resume_cmd "$sel_id")
                  if [[ "$wt_mode_act" == "none" ]]; then
                    _tmux_launch_claude "$sel_id" "$sel_rpath" "$resume_cmd"
                  else
                    local wt_a=$(find_worktree_path "$sel_id" "$sel_rpath")
                    [[ -n "$wt_a" ]] && _tmux_launch_claude "$sel_id" "$wt_a" "$resume_cmd"
                  fi
                fi
                cursor_show
                _tmux_focus_task_runtime "$sel_id" || true
                cursor_hide
                ;;
              done)
                # Reopen: restart Claude session from repo root
                cursor_show
                stty echo
                local task_title_done="${_task_title[$sel_id]}"
                echo ""
                echo "${C_CYAN}Reopening '${sel_id}': ${task_title_done}${C_RESET}"
                printf "${C_CYAN}Prompt for Claude (or Enter to continue previous session): ${C_RESET}"
                local reopen_prompt=""
                read -r reopen_prompt
                stty -echo
                cursor_hide
                local dash_claude_cmd
                if [[ -n "$reopen_prompt" ]]; then
                  local escaped="${reopen_prompt//\'/\'\\\'\'}"
                  dash_claude_cmd="claude --dangerously-skip-permissions '${escaped}'"
                else
                  dash_claude_cmd=$(_build_claude_resume_cmd "$sel_id")
                fi
                _tmux_launch_claude "$sel_id" "$sel_rpath" "$dash_claude_cmd"
                set_task_status "$sel_id" "active"
                update_task_field "$sel_id" "worktree_mode" "none"
                update_task_field_raw "$sel_id" "branch" "null"
                update_task_field_raw "$sel_id" "completed_at" "null"
                cursor_show
                tmux_select_window "$sel_id"
                cursor_hide
                ;;
            esac
          fi
        fi
        ;;
      '>'|'.') # Move task right
        if _get_active_task_id; then
          local sel_id="$_tid"
          local mv_status="${_task_status[$sel_id]}"
          local -a status_order=("pending" "paused" "active" "needs_review" "done")
          local mv_idx=-1
          for (( i=0; i<${#status_order[@]}; i++ )); do
            [[ "${status_order[$i]}" == "$mv_status" ]] && mv_idx=$i
          done
          if [[ $mv_idx -ge 0 && $mv_idx -lt $((${#status_order[@]} - 1)) ]]; then
            local next_status="${status_order[$((mv_idx + 1))]}"
            if [[ "$mv_status" == "needs_review" && "$next_status" == "done" ]]; then
              (cmd_done "$sel_id") 2>&1 || true
            else
              set_task_status "$sel_id" "$next_status"
            fi
            [[ "$_view_mode" == "list" ]] && _list_follow_id="$sel_id"
          fi
        fi
        ;;
      '<'|',') # Move task left
        if _get_active_task_id; then
          local sel_id="$_tid"
          local mv_status="${_task_status[$sel_id]}"
          local -a status_order=("pending" "paused" "active" "needs_review" "done")
          local mv_idx=-1
          for (( i=0; i<${#status_order[@]}; i++ )); do
            [[ "${status_order[$i]}" == "$mv_status" ]] && mv_idx=$i
          done
          if [[ $mv_idx -gt 0 ]]; then
            local prev_status="${status_order[$((mv_idx - 1))]}"
            set_task_status "$sel_id" "$prev_status"
            [[ "$_view_mode" == "list" ]] && _list_follow_id="$sel_id"
          fi
        fi
        ;;
      ':') # Move card up in column (kanban only; list handles its own)
        if [[ "$_view_mode" != "kanban" ]]; then true
        elif _get_selected_id; then
          local sel_id="$_tid"
          local active_repo
          if [[ "$filter_mode" != "all" ]]; then
            active_repo="$filter_mode"
          else
            active_repo="${_repo_names[$cur_repo_idx]:-}"
          fi
          local ckey="${active_repo}:${cur_col}"
          local crow="${cur_card_row[$ckey]:-0}"
          if [[ $crow -gt 0 ]]; then
            # Get the task above
            _get_repo_task_at "$active_repo" "$cur_col" "$((crow - 1))"
            local above_id="$_tid"
            if [[ -n "$above_id" ]]; then
              _swap_tasks_in_state "$sel_id" "$above_id"
              cur_card_row[$ckey]=$((crow - 1))
            fi
          fi
        fi
        ;;
      '"') # Move card down in column (kanban only; list handles its own)
        if [[ "$_view_mode" != "kanban" ]]; then true
        elif _get_selected_id; then
          local sel_id="$_tid"
          local active_repo
          if [[ "$filter_mode" != "all" ]]; then
            active_repo="$filter_mode"
          else
            active_repo="${_repo_names[$cur_repo_idx]:-}"
          fi
          local ckey="${active_repo}:${cur_col}"
          local crow="${cur_card_row[$ckey]:-0}"
          local max_idx=$(( ${_repo_col_cnt[$ckey]:-0} - 1 ))
          if [[ $crow -lt $max_idx ]]; then
            # Get the task below
            _get_repo_task_at "$active_repo" "$cur_col" "$((crow + 1))"
            local below_id="$_tid"
            if [[ -n "$below_id" ]]; then
              _swap_tasks_in_state "$sel_id" "$below_id"
              cur_card_row[$ckey]=$((crow + 1))
            fi
          fi
        fi
        ;;
      c) # Create new task or cron job (unified modal)
        # Determine context-aware type default
        local -i _mf_type=0  # 0=task, 1=cron
        if [[ "$_view_mode" == "list" ]]; then
          local _c_item="${_list_items[$_list_cursor]:-}"
          if [[ "$_c_item" == cron_group:* || "$_c_item" == cron:* ]]; then
            _mf_type=1
          fi
        elif [[ $cron_row_selected -eq 1 ]]; then
          _mf_type=1
        fi

        # Small terminal fallback (< 40 cols): sequential prompts
        local _c_cols
        _c_cols=$(tput cols)
        if [[ $_c_cols -lt 40 ]]; then
          cursor_show
          stty echo
          echo ""
          local _cancelled=false

          # Type selection
          echo "${C_CYAN}What to create (Esc to cancel):${C_RESET}"
          echo "  1) Task"
          echo "  2) Cron Job"
          printf "${C_CYAN}Choice [1]: ${C_RESET}"
          local _st_choice=""
          if ! _read_or_esc _st_choice; then _cancelled=true; fi
          [[ -z "$_st_choice" ]] && _st_choice="1"
          if [[ "$_st_choice" == "2" ]]; then _mf_type=1; fi

          # Repo selection
          local new_repo=""
          if ! $_cancelled; then
            if [[ "$filter_mode" != "all" ]]; then
              new_repo="$filter_mode"
            else
              echo "${C_CYAN}Select repo (Esc to cancel):${C_RESET}"
              local -a picker_repos=()
              local picker_idx=1
              for rn in "${_repo_names[@]}"; do
                [[ -n "${_repo_stale[$rn]:-}" ]] && continue
                picker_repos+=("$rn")
                echo "  ${picker_idx}) ${rn}"
                picker_idx=$((picker_idx + 1))
              done
              if [[ ${#picker_repos[@]} -eq 0 ]]; then
                echo "${C_RED}No repos available${C_RESET}"
                sleep 1
                stty -echo
                cursor_hide
                continue
              elif [[ ${#picker_repos[@]} -eq 1 ]]; then
                new_repo="${picker_repos[0]}"
              else
                printf "${C_CYAN}Choice: ${C_RESET}"
                local pchoice=""
                if ! _read_or_esc pchoice; then _cancelled=true; fi
                if ! $_cancelled && [[ -n "$pchoice" ]]; then
                  if [[ "$pchoice" =~ ^[0-9]+$ ]]; then
                    pchoice=$((pchoice - 1))
                    if [[ $pchoice -ge 0 && $pchoice -lt ${#picker_repos[@]} ]]; then
                      new_repo="${picker_repos[$pchoice]}"
                    else
                      echo "${C_RED}Invalid choice (out of range)${C_RESET}"
                      sleep 1
                    fi
                  else
                    echo "${C_RED}Invalid choice (not a number)${C_RESET}"
                    sleep 1
                  fi
                fi
              fi
            fi
          fi

          if ! $_cancelled && [[ -n "$new_repo" ]]; then
            if [[ $_mf_type -eq 0 ]]; then
              # === Task creation (existing path) ===
              printf "${C_CYAN}Title (Enter to skip, Esc to cancel): ${C_RESET}"
              local new_title=""
              if ! _read_or_esc new_title; then _cancelled=true; fi
              if ! $_cancelled; then
                local add_output
                add_output=$( (cmd_add --title "$new_title" --repo "$new_repo" --no-worktree) 2>&1 ) || true
                [[ -n "$add_output" ]] && echo "$add_output"
                local new_id=""
                new_id=$(echo "$add_output" | grep -oE 't-[0-9]+' | head -1)
                if [[ -n "$new_id" ]]; then
                  printf "${C_CYAN}Prompt (Enter to skip, Esc to cancel): ${C_RESET}"
                  local new_prompt=""
                  if _read_or_esc new_prompt; then
                    local start_output
                    start_output=$( (cmd_start "$new_id" "$new_prompt") 2>&1 ) || true
                    [[ -n "$start_output" ]] && echo "$start_output"
                  fi
                fi
              fi
            else
              # === Cron creation (small terminal) ===
              printf "${C_CYAN}Job name (e.g. morning-routine, Esc to cancel): ${C_RESET}"
              local _st_name=""
              if ! _read_or_esc _st_name; then _cancelled=true; fi
              if ! $_cancelled && [[ -n "$_st_name" ]]; then
                echo "${C_CYAN}Schedule type:${C_RESET}"
                echo "  1) Daily at HH:MM"
                echo "  2) Weekdays at HH:MM"
                echo "  3) Hourly (within a time range)"
                echo "  4) Every N minutes (within a time range)"
                printf "${C_CYAN}Choice [1-4]: ${C_RESET}"
                local _st_sched=""
                if ! _read_or_esc _st_sched; then _cancelled=true; fi
                [[ -z "$_st_sched" ]] && _st_sched="1"
                local -i _st_sched_type=0
                case "$_st_sched" in
                  2) _st_sched_type=1 ;; 3) _st_sched_type=2 ;; 4) _st_sched_type=3 ;; *) _st_sched_type=0 ;;
                esac
              fi
              if ! $_cancelled && [[ -n "$_st_name" ]]; then
                # Gather schedule sub-fields
                local _st_time="" _st_start_h="" _st_end_h="" _st_at_min="" _st_interval=""
                case $_st_sched_type in
                  0|1)
                    printf "${C_CYAN}Time (HH:MM, 24h) [09:00]: ${C_RESET}"
                    _read_or_esc _st_time || _cancelled=true
                    [[ -z "$_st_time" ]] && _st_time="09:00"
                    ;;
                  2)
                    printf "${C_CYAN}Start hour (0-23) [9]: ${C_RESET}"
                    _read_or_esc _st_start_h || _cancelled=true
                    [[ -z "$_st_start_h" ]] && _st_start_h="9"
                    if ! $_cancelled; then
                      printf "${C_CYAN}End hour (0-23) [17]: ${C_RESET}"
                      _read_or_esc _st_end_h || _cancelled=true
                      [[ -z "$_st_end_h" ]] && _st_end_h="17"
                    fi
                    if ! $_cancelled; then
                      printf "${C_CYAN}At minute (0-59) [0]: ${C_RESET}"
                      _read_or_esc _st_at_min || _cancelled=true
                      [[ -z "$_st_at_min" ]] && _st_at_min="0"
                    fi
                    ;;
                  3)
                    printf "${C_CYAN}Interval in minutes (1-59) [30]: ${C_RESET}"
                    _read_or_esc _st_interval || _cancelled=true
                    [[ -z "$_st_interval" ]] && _st_interval="30"
                    if ! $_cancelled; then
                      printf "${C_CYAN}Start hour (0-23) [9]: ${C_RESET}"
                      _read_or_esc _st_start_h || _cancelled=true
                      [[ -z "$_st_start_h" ]] && _st_start_h="9"
                    fi
                    if ! $_cancelled; then
                      printf "${C_CYAN}End hour (0-23) [17]: ${C_RESET}"
                      _read_or_esc _st_end_h || _cancelled=true
                      [[ -z "$_st_end_h" ]] && _st_end_h="17"
                    fi
                    ;;
                esac
              fi
              if ! $_cancelled && [[ -n "$_st_name" ]]; then
                printf "${C_CYAN}Prompt (Esc to cancel): ${C_RESET}"
                local _st_prompt=""
                if ! _read_or_esc _st_prompt; then _cancelled=true; fi
              fi
              if ! $_cancelled && [[ -n "$_st_name" && -n "$_st_prompt" ]]; then
                # Set modal vars and create via _modal_create_cron
                _mf_repo="$new_repo"
                _mf_name="$_st_name"
                _mf_prompt="$_st_prompt"
                _mf_sched_type=$_st_sched_type
                _mf_sched_time="$_st_time"
                _mf_sched_start_h="$_st_start_h"
                _mf_sched_end_h="$_st_end_h"
                _mf_sched_at_min="$_st_at_min"
                _mf_sched_interval="$_st_interval"
                local cron_output
                cron_output=$(_modal_create_cron 2>&1) || true
                [[ -n "$cron_output" ]] && echo "$cron_output"
              fi
            fi
          fi
          stty -echo
          cursor_hide
          _dash_mark_snapshot_dirty
          _dash_mark_dock_dirty
          _dash_mark_layout_dirty
          continue
        fi

        # Modal state (set by _modal_open, read after return)
        local _mf_repo="" _mf_title="" _mf_prompt="" _mf_repo_hint=""
        local -i _mf_worktree=0 _mf_focus=0
        local -i _mf_repo_readonly=0 _mf_wt_locked=0
        local -i _mf_dropdown_open=0 _mf_dropdown_idx=0
        local -i _mf_prev_top=0 _mf_prev_height=0
        local -a _mf_repo_list=()
        # Cron modal state
        local _mf_name=""
        local -i _mf_sched_type=0 _mf_sched_dd_open=0 _mf_sched_dd_idx=0
        local _mf_sched_time="" _mf_sched_start_h="" _mf_sched_end_h=""
        local _mf_sched_at_min="" _mf_sched_interval=""

        if _modal_open; then
          if [[ $_mf_type -eq 0 ]]; then
            # === Task creation (existing path) ===
            local add_args=(--title "$_mf_title" --repo "$_mf_repo")
            [[ $_mf_worktree -eq 0 ]] && add_args+=(--no-worktree)

            local add_output
            add_output=$( (cmd_add "${add_args[@]}") 2>&1 ) || true
            local new_id=""
            new_id=$(echo "$add_output" | grep -oE 't-[0-9]+' | head -1)

            if [[ -n "$new_id" ]]; then
              _modal_render_success "$new_id"
              sleep 1
              if [[ "$_view_mode" == "list" ]]; then
                # Open in split pane instead of full-screen window
                local _split_initial_prompt="$_mf_prompt"
                _list_follow_id="$new_id"
                _list_needs_rebuild=1
                if [[ "${_split_active:-0}" == "1" ]]; then
                  _split_switch_session "$new_id"
                else
                  _split_open "$new_id"
                fi
              else
                local start_output
                start_output=$( (cmd_start "$new_id" "$_mf_prompt") 2>&1 ) || true
              fi
            fi
          else
            # === Cron creation (modal) ===
            local cron_output
            cron_output=$(_modal_create_cron 2>&1) || true
            local new_cron_id=""
            new_cron_id=$(echo "$cron_output" | grep -oE 'cj-[0-9]+' | head -1)
            if [[ -n "$new_cron_id" ]]; then
              _modal_render_cron_success "$new_cron_id"
              sleep 1
              # Navigate to cron row, Scheduled column
              cron_row_selected=1
              cur_cron_col=0
              cur_cron_card_row[0]=0
            fi
          fi
        fi
        stty -echo 2>/dev/null  # Restore dashboard terminal state after modal
        ;;
      x) # Done/delete selected task OR cron toggle/review
        if [[ "$_view_mode" == "list" ]] && _list_get_selected_cron_id; then
          local cron_item="$_tid"
          _list_get_cron_col
          case $_list_cron_col in
            0)  # Scheduled: toggle enable/disable
              local is_enabled="${_cron_job_enabled[$cron_item]:-true}"
              cursor_show
              stty echo
              if [[ "$is_enabled" == "true" ]]; then
                printf "${C_YELLOW}Disable cron job ${cron_item}? [y/N]: ${C_RESET}"
                local dconfirm=""
                read -r dconfirm
                [[ "$dconfirm" =~ ^[yY]$ ]] && (cmd_cron_disable "$cron_item") 2>&1 || true
              else
                printf "${C_CYAN}Enable cron job ${cron_item}? [Y/n]: ${C_RESET}"
                local econfirm=""
                read -r econfirm
                [[ ! "$econfirm" =~ ^[nN]$ ]] && (cmd_cron_enable "$cron_item") 2>&1 || true
              fi
              stty -echo
              cursor_hide
              ;;
            2)  # Needs Review: mark reviewed
              (cmd_cron_review "$cron_item") 2>&1 || true
              ;;
            3)  # Done: archive
              update_cron_run_field "$cron_item" "status" "archived"
              ;;
          esac
        elif [[ "$_view_mode" == "kanban" && $cron_row_selected -eq 1 ]] && _get_selected_cron_id; then
          local cron_item="$_tid"
          case $cur_cron_col in
            0)  # Scheduled: toggle enable/disable
              local is_enabled="${_cron_job_enabled[$cron_item]:-true}"
              cursor_show
              stty echo
              if [[ "$is_enabled" == "true" ]]; then
                printf "${C_YELLOW}Disable cron job ${cron_item}? [y/N]: ${C_RESET}"
                local dconfirm=""
                read -r dconfirm
                [[ "$dconfirm" =~ ^[yY]$ ]] && (cmd_cron_disable "$cron_item") 2>&1 || true
              else
                printf "${C_CYAN}Enable cron job ${cron_item}? [Y/n]: ${C_RESET}"
                local econfirm=""
                read -r econfirm
                [[ ! "$econfirm" =~ ^[nN]$ ]] && (cmd_cron_enable "$cron_item") 2>&1 || true
              fi
              stty -echo
              cursor_hide
              ;;
            2)  # Needs Review: mark reviewed (moves to Done)
              (cmd_cron_review "$cron_item") 2>&1 || true
              ;;
            3)  # Done: archive (remove from dashboard)
              update_cron_run_field "$cron_item" "status" "archived"
              ;;
          esac
        elif _get_active_task_id; then
          local sel_id="$_tid"
          local sel_status="${_task_status[$sel_id]}"
          if [[ "$sel_status" == "done" ]]; then
            (cmd_rm "$sel_id") 2>&1 || true
          else
            (cmd_done "$sel_id") 2>&1 || true
          fi
        fi
        ;;
      d) # Toggle show/hide done tasks
        if [[ "$_show_done" == "1" ]]; then
          _show_done=0
        else
          _show_done=1
        fi
        if [[ "$_view_mode" == "list" ]]; then
          _list_needs_rebuild=1
        fi
        ;;
      s) # Shell popup
        if _get_active_task_id; then
          local sel_id="$_tid"
          if tmux_window_exists "$sel_id"; then
            cursor_show
            stty echo
            local pane_content
            pane_content=$(tmux_cmd capture-pane -t "board:${sel_id}" -p -S -500 2>/dev/null || echo "(no output)")
            echo "$pane_content" | less -R +G
            stty -echo
            cursor_hide
          fi
        fi
        ;;
      R) # Register a new repo
        cursor_show
        stty echo
        echo ""
        printf "${C_CYAN}Path to register (drag folder or Esc to cancel): ${C_RESET}"
        local new_repo_path=""
        if _read_or_esc new_repo_path; then
          # Sanitize path: strip whitespace, CR, and dequote (handles drag-and-drop backslash paths)
          new_repo_path="${new_repo_path%$'\r'}"    # strip trailing CR (Windows paste)
          new_repo_path="${new_repo_path## }"       # strip leading space
          new_repo_path="${new_repo_path%% }"       # strip trailing space
          new_repo_path="${(Q)new_repo_path}"       # dequote: handles \" \' and backslash-escaped spaces
          if [[ -n "$new_repo_path" ]]; then
            local reg_output
            reg_output=$( (cmd_repo_add "$new_repo_path") 2>&1 ) || true
            if [[ -n "$reg_output" ]]; then
              echo "$reg_output"
              sleep 1.5
            fi
          fi
        fi
        stty -echo
        cursor_hide
        ;;
      S) # Import an existing Claude session
        cursor_show
        stty echo
        echo ""
        local session_uid="" _s_cancelled=false
        printf "${C_CYAN}Claude session UID (Esc to cancel): ${C_RESET}"
        if ! _read_or_esc session_uid; then _s_cancelled=true; fi
        session_uid="${session_uid## }"
        session_uid="${session_uid%% }"
        if ! $_s_cancelled && [[ -n "$session_uid" ]]; then
          # Auto-detect repo
          local sess_repo=""
          sess_repo=$(_find_session_repo "$session_uid") || true
          if [[ -z "$sess_repo" ]]; then
            # Fallback: use filtered repo or picker
            if [[ "$filter_mode" != "all" ]]; then
              sess_repo="$filter_mode"
              echo "${C_DIM}Session not found in Claude projects; using filtered repo '${sess_repo}'${C_RESET}"
            else
              echo "${C_YELLOW}Could not auto-detect repo. Select one (Esc to cancel):${C_RESET}"
              local -a sp_repos=()
              local sp_idx=1
              for rn in "${_repo_names[@]}"; do
                [[ -n "${_repo_stale[$rn]:-}" ]] && continue
                sp_repos+=("$rn")
                echo "  ${sp_idx}) ${rn}"
                sp_idx=$((sp_idx + 1))
              done
              if [[ ${#sp_repos[@]} -eq 1 ]]; then
                sess_repo="${sp_repos[0]}"
              elif [[ ${#sp_repos[@]} -gt 1 ]]; then
                printf "${C_CYAN}Choice: ${C_RESET}"
                local sp_choice=""
                if ! _read_or_esc sp_choice; then _s_cancelled=true; fi
                if ! $_s_cancelled && [[ "$sp_choice" =~ ^[0-9]+$ ]]; then
                  sp_choice=$((sp_choice - 1))
                  if [[ $sp_choice -ge 0 && $sp_choice -lt ${#sp_repos[@]} ]]; then
                    sess_repo="${sp_repos[$sp_choice]}"
                  fi
                fi
              fi
            fi
          else
            echo "${C_GREEN}Detected repo: ${sess_repo}${C_RESET}"
          fi
          if ! $_s_cancelled && [[ -n "$sess_repo" ]]; then
            printf "${C_CYAN}Title (Enter to skip, Esc to cancel): ${C_RESET}"
            local sess_title=""
            if ! _read_or_esc sess_title; then _s_cancelled=true; fi
            if ! $_s_cancelled; then
              local sess_output
              local sess_args=("$session_uid" --repo "$sess_repo")
              [[ -n "$sess_title" ]] && sess_args+=(--title "$sess_title")
              sess_output=$( (cmd_session "${sess_args[@]}") 2>&1 ) || true
              if [[ -n "$sess_output" ]]; then
                echo "$sess_output"
              fi
            fi
          fi
        fi
        stty -echo
        cursor_hide
        ;;
      t) # Rename focused task
        if _get_active_task_id; then
          local sel_id="$_tid"
          local cur_title="${_task_title[$sel_id]}"
          cursor_show
          stty echo
          echo ""
          printf "${C_CYAN}Rename '${sel_id}' [${cur_title}] (Esc to cancel): ${C_RESET}"
          local rename_input=""
          if _read_or_esc rename_input && [[ -n "$rename_input" ]]; then
            update_task_field "$sel_id" "title" "$rename_input"
          fi
          stty -echo
          cursor_hide
        fi
        ;;
      p) # Pause active task
        if _get_active_task_id; then
          local sel_id="$_tid"
          local p_status="${_task_status[$sel_id]}"
          if [[ "$p_status" == "active" || "$p_status" == "needs_review" ]]; then
            _tmux_close_task_runtime "$sel_id" || true
            set_task_status "$sel_id" "paused"
            update_task_field_raw "$sel_id" "claude_status" "null"
          fi
        fi
        ;;
      r) # Reopen done task
        if _get_active_task_id; then
          local sel_id="$_tid"
          local r_status="${_task_status[$sel_id]}"
          if [[ "$r_status" == "done" ]]; then
            local sel_repo="${_task_repo[$sel_id]}"
            local sel_rpath
            sel_rpath=$(repo_path "$sel_repo")
            if [[ -n "${_repo_stale[$sel_repo]:-}" ]]; then
              cursor_show
              stty echo
              echo ""
              echo "${C_RED}Repo path not found. Run: cloard-board repo update-path ${sel_repo} <new-path>${C_RESET}"
              sleep 2
              stty -echo
              cursor_hide
            else
              cursor_show
              stty echo
              local task_title="${_task_title[$sel_id]}"
              echo ""
              echo "${C_CYAN}Reopening '${sel_id}': ${task_title}${C_RESET}"
              printf "${C_CYAN}Prompt for Claude (or Enter to continue previous session): ${C_RESET}"
              local reopen_prompt=""
              read -r reopen_prompt
              stty -echo
              cursor_hide
              local dash_claude_cmd
              if [[ -n "$reopen_prompt" ]]; then
                local escaped="${reopen_prompt//\'/\'\\\'\'}"
                local new_uid
                new_uid=$(uuidgen | tr '[:upper:]' '[:lower:]')
                dash_claude_cmd="claude --session-id ${new_uid} --dangerously-skip-permissions '${escaped}'"
                push_session_history "$sel_id" "$new_uid"
              else
                dash_claude_cmd=$(_build_claude_resume_cmd "$sel_id")
              fi
              _tmux_launch_claude "$sel_id" "$sel_rpath" "$dash_claude_cmd"
              set_task_status "$sel_id" "active"
              update_task_field "$sel_id" "worktree_mode" "none"
              update_task_field_raw "$sel_id" "branch" "null"
              update_task_field_raw "$sel_id" "completed_at" "null"
              tmux_select_window "$sel_id"
            fi
          fi
        fi
        ;;
      H) # Session history
        if _get_active_task_id; then
          local sel_id="$_tid"
          if _session_history_modal "$sel_id"; then
            # User selected a session; relaunch with updated session_uid
            local sel_repo="${_task_repo[$sel_id]}"
            local sel_rpath
            sel_rpath=$(repo_path "$sel_repo")

            # Close split pane if showing this task
            local was_split=0
            if [[ "${_split_active:-0}" == "1" && "$_split_task_id" == "$sel_id" ]]; then
              _split_close keep
              was_split=1
            fi

            # Kill existing window and relaunch with the selected session
            tmux_kill_window "$sel_id"
            local resume_cmd
            resume_cmd=$(_build_claude_resume_cmd "$sel_id")
            local wt_mode="${_task_wtmode[$sel_id]}"
            if [[ "$wt_mode" == "none" ]]; then
              _tmux_launch_claude "$sel_id" "$sel_rpath" "$resume_cmd"
            else
              local wt_p
              wt_p=$(find_worktree_path "$sel_id" "$sel_rpath")
              _tmux_launch_claude "$sel_id" "${wt_p:-$sel_rpath}" "$resume_cmd"
            fi

            if [[ $was_split -eq 1 ]]; then
              # Re-open in split pane
              _split_open "$sel_id"
            else
              cursor_show
              tmux_select_window "$sel_id"
              cursor_hide
            fi
          fi
        fi
        ;;
      D) # Delete cron job (from dashboard)
        if [[ "$_view_mode" == "kanban" && $cron_row_selected -eq 1 && $cur_cron_col -eq 0 ]] && _get_selected_cron_id; then
          local cron_item="$_tid"
          cursor_show
          stty echo
          echo ""
          (cmd_cron_remove "$cron_item") 2>&1 || true
          stty -echo
          cursor_hide
        fi
        ;;
      v) # Toggle kanban/list view
        _dash_toggle_view_mode
        ;;
      q) # Quit / detach
        if [[ $_split_active -eq 1 ]]; then
          _split_close keep
        fi
        cursor_show
        tmux_cmd detach-client 2>/dev/null || exit 0
        exit 0
        ;;
    esac

    # ── List mode key dispatch (navigation + list-specific keys) ──
    if [[ "$_view_mode" == "list" ]]; then
      case "$key" in
        j|k|$'\t'|SHIFT_TAB|D|b|l|F|ESC|':'|'"')
          _list_handle_key "$key"
          ;;
        $'\n'|$'\r') # Enter in list mode
          _list_handle_key "ENTER"
          ;;
      esac
    fi

    if [[ "$_view_mode" != "$_prev_view_mode" ]]; then
      _dash_mark_layout_dirty
      _dash_mark_list_dirty
    fi

    if [[ "${_split_active:-0}" != "$_prev_split_active" || "$_split_task_id" != "$_prev_split_task_id" || "${_split_is_cron:-0}" != "$_prev_split_is_cron" ]]; then
      _dash_mark_dock_dirty
      _dash_mark_layout_dirty
      _dash_mark_list_dirty
    fi

    if [[ "$_show_done" != "$_prev_show_done" || "$filter_mode" != "$_prev_filter_mode" ]]; then
      _dash_mark_list_dirty
    fi

    case "$key" in
      '') ;;
      $'\n'|$'\r'|'>'|'<'|':'|'"'|c|x|R|S|t|p|r|H|D)
        _dash_mark_snapshot_dirty
        ;;
      d)
        _dash_mark_list_dirty
        ;;
    esac

    _full_redraw=0

  done
}

# Helper: get selected task ID regardless of view mode
_get_active_task_id() {
  case "$_view_mode" in
    kanban) _get_selected_id ;;
    list)   _list_get_selected_id ;;
  esac
}

# ── Context transfer functions ────────────────────────────────────────────────

# Transfer state from kanban to list mode
_list_transfer_from_kanban() {
  _list_group_collapsed=()  # expand all groups by default

  # If caller pre-set _list_follow_id (e.g. kanban cron Enter), preserve it
  if [[ -n "${_list_follow_id:-}" ]]; then
    # Ensure __cron group is expanded when following a cron item
    [[ "${_list_follow_type:-task}" == "cron" ]] && unset '_list_group_collapsed[__cron]'
  elif _get_selected_id 2>/dev/null; then
    _list_follow_id="$_tid"
  elif [[ $cron_row_selected -eq 1 ]]; then
    # Cron row selected but no specific task ID; expand cron group
    _list_follow_type="cron"
    unset '_list_group_collapsed[__cron]'
  elif [[ ${#_repo_names[@]} -gt 0 ]]; then
    # Position at current repo's group header
    _list_follow_id=""
    # Expand the current repo, collapse others if many
    if [[ ${#_repo_names[@]} -gt 6 ]]; then
      for rn in "${_repo_names[@]}"; do
        _list_group_collapsed[$rn]=1
      done
      local cur_rname="${_repo_names[$cur_repo_idx]:-}"
      [[ -n "$cur_rname" ]] && unset "_list_group_collapsed[$cur_rname]"
    fi
  fi

  # Build items immediately so _list_follow_id takes effect
  _list_build_items
}

# Transfer state from list mode back to kanban
_list_transfer_to_kanban() {
  local item="${_list_items[$_list_cursor]:-}"

  case "$item" in
    task:*)
      local tid="${item#task:}"
      local trepo="${_task_repo[$tid]:-}"
      local tst="${_task_status[$tid]:-}"

      # Set filter to the task's repo
      if [[ -n "$trepo" ]]; then
        # Find repo index
        local ri=0
        for rn in "${_repo_names[@]}"; do
          [[ "$rn" == "$trepo" ]] && break
          ri=$((ri + 1))
        done
        if [[ $ri -lt ${#_repo_names[@]} ]]; then
          cur_repo_idx=$ri
        fi
        # Set column based on status
        case "$tst" in
          pending|paused) cur_col=0 ;;
          active)         cur_col=1 ;;
          needs_review)   cur_col=2 ;;
          done)           cur_col=3 ;;
        esac
        nav_mode="card"

        # Try to find task row in column
        local ids_str="${_repo_cols[${trepo}:${cur_col}]:-}"
        if [[ -n "$ids_str" ]]; then
          local -a ids_arr=(${(s: :)ids_str})
          local ti=0
          for id in "${ids_arr[@]}"; do
            [[ "$id" == "$tid" ]] && break
            ti=$((ti + 1))
          done
          cur_card_row["${trepo}:${cur_col}"]=$ti
        fi
      fi
      cron_row_selected=0
      ;;
    group:*)
      local rname="${item#group:}"
      local ri=0
      for rn in "${_repo_names[@]}"; do
        [[ "$rn" == "$rname" ]] && break
        ri=$((ri + 1))
      done
      [[ $ri -lt ${#_repo_names[@]} ]] && cur_repo_idx=$ri
      nav_mode="repo"
      cron_row_selected=0
      ;;
    cron_group:*|cron:*)
      cron_row_selected=1
      nav_mode="card"
      ;;
    *)
      nav_mode="repo"
      cron_row_selected=0
      ;;
  esac

  # Close split if active
  if [[ $_split_active -eq 1 ]]; then
    _split_close keep
  fi
}
