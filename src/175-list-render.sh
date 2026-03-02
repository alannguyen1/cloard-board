# ── List mode render + key handler ────────────────────────────────────────────
# Pure render functions that append to _frame. They rely on zsh dynamic scoping
# to access variables declared local in cmd__dash_loop.

# ── Height / offset helpers ──────────────────────────────────────────────────

# Return the display height of item at index $1. Result in _lih (avoids subshell).
_list_item_height() {
  local item="${_list_items[$1]:-}"
  case "$item" in
    group:*|cron_group:*) _lih=1 ;;
    task:*|cron:*)        _lih=2 ;;
    *)                    _lih=1 ;;
  esac
}

# Compute the content-line offset of item at index $1 by summing heights of all
# preceding items. Result in _lcl (avoids subshell).
_list_content_line_of() {
  local _idx="$1"
  _lcl=0
  local _li
  for (( _li=0; _li<_idx; _li++ )); do
    _list_item_height "$_li"
    _lcl=$((_lcl + _lih))
  done
}

# ── Scroll management ───────────────────────────────────────────────────────

# Ensure the cursor item is within the visible viewport. Adjusts _list_scroll_top.
_list_adjust_scroll() {
  local viewport_height=$((rows - 3))
  [[ $viewport_height -lt 1 ]] && viewport_height=1

  _list_content_line_of "$_list_cursor"
  local cursor_line=$_lcl

  _list_item_height "$_list_cursor"
  local cursor_bottom=$((cursor_line + _lih - 1))

  # Scroll down if cursor extends below viewport
  if [[ $cursor_bottom -ge $((_list_scroll_top + viewport_height)) ]]; then
    _list_scroll_top=$((cursor_bottom - viewport_height + 1))
  fi

  # Scroll up if cursor is above viewport
  if [[ $cursor_line -lt $_list_scroll_top ]]; then
    _list_scroll_top=$cursor_line
  fi
}

# ── Group headers ────────────────────────────────────────────────────────────

# Render a repo group header line. Appends to _frame.
# $1 = repo_name, $2 = 1 if selected, 0 otherwise
_render_list_group_header() {
  local repo_name="$1"
  local is_selected="$2"

  local total="${_repo_task_count[$repo_name]:-0}"
  local active_cnt="${_repo_col_cnt[${repo_name}:1]:-0}"
  local review_cnt="${_repo_col_cnt[${repo_name}:2]:-0}"

  local arrow="▼"
  [[ "${_list_group_collapsed[$repo_name]:-}" == "1" ]] && arrow="▶"

  local hdr_text="${arrow} ${repo_name} (${total} tasks: ${active_cnt} active, ${review_cnt} review)"
  local _hpad="${(r:${cols}:)hdr_text}"

  if [[ "$is_selected" == "1" ]]; then
    _frame+="${C_BOLD}${C_BG_BLUE}${C_WHITE}${_hpad}${C_RESET}"
  else
    _frame+="${C_BOLD}${_hpad}${C_RESET}"
  fi
  _frame+=$'\n'
}

# Render the cron group header line. Appends to _frame.
# $1 = 1 if selected, 0 otherwise
_render_list_cron_header() {
  local is_selected="$1"

  local cron_total=0
  local _ci
  for _ci in {0..2}; do
    cron_total=$((cron_total + ${_cron_col_cnt[__cron:${_ci}]:-0}))
  done

  local arrow="▼"
  [[ "${_list_group_collapsed[__cron]:-}" == "1" ]] && arrow="▶"

  local hdr_text="${arrow} cron jobs (${cron_total} items)"
  local _hpad="${(r:${cols}:)hdr_text}"

  if [[ "$is_selected" == "1" ]]; then
    _frame+="${C_BOLD}${C_BG_BLUE}${C_WHITE}${_hpad}${C_RESET}"
  else
    _frame+="${C_BOLD}${_hpad}${C_RESET}"
  fi
  _frame+=$'\n'
}

# ── Task card (2 lines) ─────────────────────────────────────────────────────

# Render a two-line task card. Appends to _frame.
# $1 = task_id, $2 = available width, $3 = 1 if selected
_render_list_task_card() {
  local task_id="$1"
  local width="$2"
  local is_selected="$3"

  local title="${_task_title[$task_id]:-}"
  local tstatus="${_task_status[$task_id]:-}"
  local claude="${_task_claude[$task_id]:-}"
  local pr="${_task_pr[$task_id]:-}"

  # Status badge
  local badge="" badge_color=""
  case "$tstatus" in
    active)       badge="● Active";       badge_color="$C_GREEN" ;;
    needs_review) badge="◆ Review";       badge_color="$C_YELLOW" ;;
    pending)      badge="○ Pending";      badge_color="$C_DIM" ;;
    paused)       badge="◫ Paused";       badge_color="$C_CYAN" ;;
    done)         badge="✓ Done";         badge_color="$C_DIM" ;;
  esac

  # Claude status indicator
  local claude_str=""
  [[ "$claude" == "working" ]] && claude_str="  ⚙ working"
  [[ "$claude" == "waiting" ]] && claude_str="  ○ waiting"

  # PR short
  local pr_short=""
  if [[ -n "$pr" ]]; then
    pr_short=$(echo "$pr" | command grep -oE '#[0-9]+' 2>/dev/null || echo "PR")
    pr_short="  ${pr_short}"
  fi

  local prefix=" "
  local sel_on="" sel_off=""
  if [[ "$is_selected" == "1" ]]; then
    prefix=">"
    sel_on="${C_BOLD}${C_BG_BLUE}${C_WHITE}"
    sel_off="${C_RESET}"
  fi

  if [[ $width -gt 35 ]]; then
    # ── Wide format ──
    # Line 1:  > t-003  Fix authentication bug
    local title_max=$((width - 10))
    [[ $title_max -lt 1 ]] && title_max=1
    local title_str
    title_str=$(trunc "$title" "$title_max")
    local _tw=$((width - 10))
    [[ $_tw -lt 0 ]] && _tw=0

    if [[ "$is_selected" == "1" ]]; then
      _frame+="${sel_on}${prefix} ${(r:6:)task_id}  ${(r:$_tw:)title_str}${sel_off}"
    else
      _frame+="${prefix} ${C_DIM}${(r:6:)task_id}${C_RESET}  ${(r:$_tw:)title_str}"
    fi
    _frame+=$'\n'

    # Line 2:           ● Active  ⚙ working  #42
    local detail="${badge}${claude_str}${pr_short}"
    local detail_max=$((width - 10))
    [[ $detail_max -lt 1 ]] && detail_max=1
    detail=$(trunc "$detail" "$detail_max")

    if [[ "$is_selected" == "1" ]]; then
      local _det_full="         ${detail}"
      _frame+="${sel_on}${(r:${width}:)_det_full}${sel_off}"
    else
      local _dpad_n=$((width - 9 - ${#detail}))
      local _e=""
      _frame+="         ${badge_color}${detail}${C_RESET}"
      [[ $_dpad_n -gt 0 ]] && _frame+="${(r:$_dpad_n:)_e}"
    fi
    _frame+=$'\n'
  else
    # ── Narrow format ──
    # Line 1: > t-003 Fix auth..  ● Active
    local badge_short
    case "$tstatus" in
      active)       badge_short="●" ;;
      needs_review) badge_short="◆" ;;
      pending)      badge_short="○" ;;
      paused)       badge_short="◫" ;;
      done)         badge_short="✓" ;;
    esac
    local title_max=$((width - ${#task_id} - 6))
    [[ $title_max -lt 4 ]] && title_max=4
    local title_str
    title_str=$(trunc "$title" "$title_max")

    local _nw=$((width - 9))
    [[ $_nw -lt 0 ]] && _nw=0
    if [[ "$is_selected" == "1" ]]; then
      _frame+="${sel_on}${prefix} ${(r:5:)task_id} ${(r:$_nw:)title_str} ${badge_short}${sel_off}"
    else
      _frame+="${prefix} ${C_DIM}${(r:5:)task_id}${C_RESET} ${(r:$_nw:)title_str} ${badge_color}${badge_short}${C_RESET}"
    fi
    _frame+=$'\n'

    # Line 2: additional info or blank
    local info_str="${claude_str:+${claude_str:2}}${pr_short}"
    local info_max=$((width - 8))
    [[ $info_max -lt 1 ]] && info_max=1
    info_str=$(trunc "$info_str" "$info_max")
    local _iw=$((width - 7))
    [[ $_iw -lt 0 ]] && _iw=0
    if [[ "$is_selected" == "1" ]]; then
      local _info_full="       ${info_str}"
      _frame+="${sel_on}${(r:${width}:)_info_full}${sel_off}"
    else
      _frame+="       ${C_DIM}${(r:$_iw:)info_str}${C_RESET}"
    fi
    _frame+=$'\n'
  fi
}

# ── Cron card (2 lines) ─────────────────────────────────────────────────────

# Render a two-line cron card. Appends to _frame.
# $1 = cron_id, $2 = available width, $3 = 1 if selected
_render_list_cron_card() {
  local cron_id="$1"
  local width="$2"
  local is_selected="$3"

  local prefix=" "
  local sel_on="" sel_off=""
  if [[ "$is_selected" == "1" ]]; then
    prefix=">"
    sel_on="${C_BOLD}${C_BG_BLUE}${C_WHITE}"
    sel_off="${C_RESET}"
  fi

  # Determine if this is a job (col 0) or a run (col 1/2)
  local rdata="${_cron_run_data[$cron_id]:-}"

  if [[ -z "$rdata" ]]; then
    # Scheduled cron job
    local jname="${_cron_jobs[$cron_id]:-$cron_id}"
    local jsched="${_cron_job_schedule[$cron_id]:-}"
    local jenabled="${_cron_job_enabled[$cron_id]:-true}"

    local status_str="scheduled"
    local status_color="$C_DIM"
    if [[ "$jenabled" != "true" ]]; then
      status_str="disabled"
      status_color="$C_RED"
    fi

    # Line 1: cron ID + job name
    local id_max=$((width - 3))
    local id_name="${cron_id}  ${jname}"
    id_name=$(trunc "$id_name" "$id_max")
    local _cw=$((width - 2))
    [[ $_cw -lt 0 ]] && _cw=0
    if [[ "$is_selected" == "1" ]]; then
      _frame+="${sel_on}${prefix} ${(r:$_cw:)id_name}${sel_off}"
    else
      _frame+="${prefix} ${C_DIM}${(r:$_cw:)id_name}${C_RESET}"
    fi
    _frame+=$'\n'

    # Line 2: schedule / status
    local detail="${status_str}"
    [[ -n "$jsched" ]] && detail="${jsched}"
    local detail_max=$((width - 9))
    [[ $detail_max -lt 1 ]] && detail_max=1
    detail=$(trunc "$detail" "$detail_max")
    local _dw=$((width - 7))
    [[ $_dw -lt 0 ]] && _dw=0
    if [[ "$is_selected" == "1" ]]; then
      local _sd_full="       ${detail}"
      _frame+="${sel_on}${(r:${width}:)_sd_full}${sel_off}"
    else
      _frame+="       ${status_color}${(r:$_dw:)detail}${C_RESET}"
    fi
    _frame+=$'\n'
  else
    # Cron run (active or needs_review)
    local rjob_id rstat recode rstart rsid rwin
    IFS=$'\x1e' read -r rjob_id rstat recode rstart rsid rwin <<< "$(echo -e "$rdata")"
    local rjname="${_cron_jobs[$rjob_id]:-$rjob_id}"

    local status_str="" status_color=""
    case "$rstat" in
      active)       status_str="● running";       status_color="$C_GREEN" ;;
      needs_review) status_str="◆ needs review";  status_color="$C_YELLOW" ;;
      reviewed)     status_str="✓ reviewed";       status_color="$C_CYAN" ;;
      *)            status_str="$rstat";           status_color="$C_DIM" ;;
    esac

    # Line 1: run ID + job name
    local id_max=$((width - 3))
    local id_name="${cron_id}  ${rjname}"
    id_name=$(trunc "$id_name" "$id_max")
    local _cw=$((width - 2))
    [[ $_cw -lt 0 ]] && _cw=0
    if [[ "$is_selected" == "1" ]]; then
      _frame+="${sel_on}${prefix} ${(r:$_cw:)id_name}${sel_off}"
    else
      _frame+="${prefix} ${C_DIM}${(r:$_cw:)id_name}${C_RESET}"
    fi
    _frame+=$'\n'

    # Line 2: status + exit code
    local exit_info=""
    [[ -n "$recode" && "$recode" != "null" && "$rstat" != "active" ]] && exit_info="  exit ${recode}"
    local detail="${status_str}${exit_info}"
    local detail_max=$((width - 9))
    [[ $detail_max -lt 1 ]] && detail_max=1
    detail=$(trunc "$detail" "$detail_max")
    local _dw=$((width - 7))
    [[ $_dw -lt 0 ]] && _dw=0
    if [[ "$is_selected" == "1" ]]; then
      local _cr_full="       ${detail}"
      _frame+="${sel_on}${(r:${width}:)_cr_full}${sel_off}"
    else
      _frame+="       ${status_color}${(r:$_dw:)detail}${C_RESET}"
    fi
    _frame+=$'\n'
  fi
}

# ── Scrollbar ────────────────────────────────────────────────────────────────

# Render a scrollbar on the right edge of the screen.
# $1 = viewport_height, $2 = total_content_lines
_render_scrollbar_track() {
  local viewport_height="$1"
  local total_content_lines="$2"

  [[ $total_content_lines -le $viewport_height ]] && return 0

  # Thumb size: at least 1 char
  local thumb_size=$((viewport_height * viewport_height / total_content_lines))
  [[ $thumb_size -lt 1 ]] && thumb_size=1

  # Thumb position
  local scrollable=$((total_content_lines - viewport_height))
  [[ $scrollable -lt 1 ]] && scrollable=1
  local track_range=$((viewport_height - thumb_size))
  local thumb_pos=$(((_list_scroll_top * track_range + scrollable / 2) / scrollable))
  [[ $thumb_pos -lt 0 ]] && thumb_pos=0
  [[ $thumb_pos -gt $track_range ]] && thumb_pos=$track_range

  local _ri
  for (( _ri=0; _ri<viewport_height; _ri++ )); do
    move_to "$((_ri + 2))" "$cols"
    if [[ $_ri -ge $thumb_pos && $_ri -lt $((thumb_pos + thumb_size)) ]]; then
      printf "${C_BOLD}█${C_RESET}"
    else
      printf "${C_DIM}│${C_RESET}"
    fi
  done
}

# ── Full-screen list renderer ────────────────────────────────────────────────

# Render the full-screen list view (no split pane).
_render_list_full() {
  local viewport_height=$((rows - 3))
  [[ $viewport_height -lt 1 ]] && viewport_height=1

  _list_adjust_scroll

  # Compute total content lines
  local total_content_lines=0
  local _rf_i
  for (( _rf_i=0; _rf_i<${#_list_items[@]}; _rf_i++ )); do
    _list_item_height "$_rf_i"
    total_content_lines=$(( total_content_lines + _lih ))
  done

  # Iterate items, tracking content line offset
  local content_line=0
  local _rf_idx
  for (( _rf_idx=0; _rf_idx<${#_list_items[@]}; _rf_idx++ )); do
    _list_item_height "$_rf_idx"
    local item_h=$_lih

    # Skip items entirely above the viewport
    if [[ $((content_line + item_h)) -le $_list_scroll_top ]]; then
      content_line=$((content_line + item_h))
      continue
    fi

    # Stop if we're past the viewport bottom
    [[ $content_line -ge $((_list_scroll_top + viewport_height)) ]] && break

    local is_sel=0
    [[ $_rf_idx -eq $_list_cursor ]] && is_sel=1

    local item="${_list_items[$_rf_idx]}"
    case "$item" in
      group:*)
        _render_list_group_header "${item#group:}" "$is_sel"
        ;;
      task:*)
        _render_list_task_card "${item#task:}" "$cols" "$is_sel"
        ;;
      cron_group:*)
        _render_list_cron_header "$is_sel"
        ;;
      cron:*)
        _render_list_cron_card "${item#cron:}" "$cols" "$is_sel"
        ;;
    esac

    content_line=$((content_line + item_h))
  done

  # Pad remaining viewport lines with empty lines
  local rendered_lines=$((content_line - _list_scroll_top))
  [[ $rendered_lines -gt $viewport_height ]] && rendered_lines=$viewport_height
  local _pad_i _e=""
  for (( _pad_i=rendered_lines; _pad_i<viewport_height; _pad_i++ )); do
    _frame+="${(r:${cols}:)_e}"
    _frame+=$'\n'
  done

  # Scrollbar (rendered after frame output, using move_to for positioning)
  if [[ $total_content_lines -gt $viewport_height ]]; then
    _list_scrollbar_vh=$viewport_height
    _list_scrollbar_total=$total_content_lines
  else
    _list_scrollbar_vh=0
    _list_scrollbar_total=0
  fi
}

# ── Sidebar task card (compact, title-first layout) ──────────────────────────

# Render a two-line sidebar task card. Title gets full width on line 1,
# id + status badge on line 2.
_render_sidebar_task_card() {
  local task_id="$1"
  local width="$2"
  local is_selected="$3"

  local title="${_task_title[$task_id]:-}"
  local tstatus="${_task_status[$task_id]:-}"
  local claude="${_task_claude[$task_id]:-}"

  # Single-char status badge
  local badge_char="" badge_color=""
  case "$tstatus" in
    active)       badge_char="●"; badge_color="$C_GREEN" ;;
    needs_review) badge_char="◆"; badge_color="$C_YELLOW" ;;
    pending)      badge_char="○"; badge_color="$C_DIM" ;;
    paused)       badge_char="◫"; badge_color="$C_CYAN" ;;
    done)         badge_char="✓"; badge_color="$C_DIM" ;;
  esac

  local claude_char=""
  [[ "$claude" == "working" ]] && claude_char=" ⚙"
  [[ "$claude" == "waiting" ]] && claude_char=" ○"

  local prefix=" "
  local sel_on="" sel_off=""
  if [[ "$is_selected" == "1" ]]; then
    prefix=">"
    sel_on="${C_BOLD}${C_BG_BLUE}${C_WHITE}"
    sel_off="${C_RESET}"
  fi

  # Line 1: > Title text here (full width minus 2 for prefix+space)
  local title_max=$((width - 2))
  [[ $title_max -lt 1 ]] && title_max=1
  local title_str
  title_str=$(trunc "$title" "$title_max")
  local _tw=$((width - 2))
  [[ $_tw -lt 0 ]] && _tw=0

  if [[ "$is_selected" == "1" ]]; then
    _frame+="${sel_on}${prefix} ${(r:$_tw:)title_str}${sel_off}"
  else
    _frame+="${sel_on}${prefix} ${(r:$_tw:)title_str}${sel_off}"
  fi
  _frame+=$'\n'

  # Line 2:   t-002 ● ⚙  (id + badge + claude indicator, dimmed)
  local detail="${task_id} ${badge_char}${claude_char}"
  local _dw=$((width - 3))
  [[ $_dw -lt 0 ]] && _dw=0
  if [[ "$is_selected" == "1" ]]; then
    local _det="  ${detail}"
    _frame+="${sel_on}${(r:${width}:)_det}${sel_off}"
  else
    _frame+="  ${C_DIM}${task_id}${C_RESET} ${badge_color}${badge_char}${C_RESET}${C_DIM}${claude_char}${C_RESET}"
    local detail_plain_len=$((${#task_id} + 1 + 1 + ${#claude_char}))
    local _pad_n=$((width - 2 - detail_plain_len))
    if [[ $_pad_n -gt 0 ]]; then
      local _e=""
      _frame+="${(r:$_pad_n:)_e}"
    fi
  fi
  _frame+=$'\n'
}

# ── Sidebar list renderer (split-pane mode) ──────────────────────────────────

# Render the list as a narrow sidebar. Same logic as _render_list_full but
# uses the narrower pane width and omits the scrollbar.
_render_list_sidebar() {
  local sidebar_w="${1:-$cols}"
  local viewport_height=$((rows - 3))
  [[ $viewport_height -lt 1 ]] && viewport_height=1

  _list_adjust_scroll

  local content_line=0
  local _rs_idx
  for (( _rs_idx=0; _rs_idx<${#_list_items[@]}; _rs_idx++ )); do
    _list_item_height "$_rs_idx"
    local item_h=$_lih

    if [[ $((content_line + item_h)) -le $_list_scroll_top ]]; then
      content_line=$((content_line + item_h))
      continue
    fi

    [[ $content_line -ge $((_list_scroll_top + viewport_height)) ]] && break

    local is_sel=0
    [[ $_rs_idx -eq $_list_cursor ]] && is_sel=1

    local item="${_list_items[$_rs_idx]}"
    case "$item" in
      group:*)
        # Slim group header for sidebar
        local rn="${item#group:}"
        local arrow="▼"
        [[ "${_list_group_collapsed[$rn]:-}" == "1" ]] && arrow="▶"
        local total="${_repo_task_count[$rn]:-0}"
        local hdr="${arrow} ${rn} (${total})"
        hdr=$(trunc "$hdr" "$sidebar_w")
        local _shpad="${(r:${sidebar_w}:)hdr}"
        if [[ $is_sel -eq 1 ]]; then
          _frame+="${C_BOLD}${C_BG_BLUE}${C_WHITE}${_shpad}${C_RESET}"
        else
          _frame+="${C_BOLD}${_shpad}${C_RESET}"
        fi
        _frame+=$'\n'
        ;;
      task:*)
        _render_sidebar_task_card "${item#task:}" "$sidebar_w" "$is_sel"
        ;;
      cron_group:*)
        _render_list_cron_header "$is_sel"
        ;;
      cron:*)
        _render_list_cron_card "${item#cron:}" "$sidebar_w" "$is_sel"
        ;;
    esac

    content_line=$((content_line + item_h))
  done

  # Pad remaining lines
  local rendered_lines=$((content_line - _list_scroll_top))
  [[ $rendered_lines -gt $viewport_height ]] && rendered_lines=$viewport_height
  local _pad_i _e=""
  for (( _pad_i=rendered_lines; _pad_i<viewport_height; _pad_i++ )); do
    _frame+="${(r:${sidebar_w}:)_e}"
    _frame+=$'\n'
  done
}

# ── Selection helpers ────────────────────────────────────────────────────────

# Get task ID of the currently selected item. Sets _tid, returns 1 if not a task.
_list_get_selected_id() {
  local item="${_list_items[$_list_cursor]:-}"
  case "$item" in
    task:*) _tid="${item#task:}" ;;
    *)      _tid=""; return 1 ;;
  esac
}

# Get cron ID of the currently selected item. Sets _tid, returns 1 if not cron.
_list_get_selected_cron_id() {
  local item="${_list_items[$_list_cursor]:-}"
  case "$item" in
    cron:*) _tid="${item#cron:}" ;;
    *)      _tid=""; return 1 ;;
  esac
}

# ── Key handler ──────────────────────────────────────────────────────────────

# Handle list-mode specific keys. Returns 1 if key was not handled (fall through
# to shared key handlers in cmd__dash_loop).
_list_handle_key() {
  local key="$1"
  local max_idx=$((${#_list_items[@]} - 1))
  [[ $max_idx -lt 0 ]] && max_idx=0

  case "$key" in
    j) # Cursor down
      if [[ $_list_cursor -lt $max_idx ]]; then
        _list_cursor=$((_list_cursor + 1))
      fi
      ;;

    k) # Cursor up
      if [[ $_list_cursor -gt 0 ]]; then
        _list_cursor=$((_list_cursor - 1))
      fi
      ;;

    ENTER|$'\n'|$'\r') # Enter
      local item="${_list_items[$_list_cursor]:-}"
      case "$item" in
        group:*)
          local gname="${item#group:}"
          if [[ "${_list_group_collapsed[$gname]:-}" == "1" ]]; then
            unset "_list_group_collapsed[$gname]"
          else
            _list_group_collapsed[$gname]=1
          fi
          _list_needs_rebuild=1
          ;;
        cron_group:*)
          if [[ "${_list_group_collapsed[__cron]:-}" == "1" ]]; then
            unset "_list_group_collapsed[__cron]"
          else
            _list_group_collapsed[__cron]=1
          fi
          _list_needs_rebuild=1
          ;;
        task:*)
          local sel_id="${item#task:}"
          if [[ "${_split_active:-0}" == "1" ]]; then
            if [[ "$sel_id" != "$_split_task_id" ]]; then
              _split_switch_session "$sel_id"
            fi
            # Focus the Claude session pane
            tmux_cmd select-pane -t "board:dashboard.1" 2>/dev/null || true
          else
            # Delegate to kanban-style Enter handling (start/resume/attach)
            local cur_status="${_task_status[$sel_id]}"
            local sel_repo="${_task_repo[$sel_id]}"
            local sel_rpath
            sel_rpath=$(repo_path "$sel_repo")

            if [[ -n "${_repo_stale[$sel_repo]:-}" ]]; then
              cursor_show; stty echo
              echo ""
              echo "${C_RED}Repo path not found. Run: cloard-board repo update-path ${sel_repo} <new-path>${C_RESET}"
              sleep 2
              stty -echo; cursor_hide
            else
              case "$cur_status" in
                pending)
                  cursor_show; stty echo
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
                  stty -echo; cursor_hide
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
                  update_task_field "$sel_id" "status" "active"
                  update_task_field "$sel_id" "started_at" "$(now_iso)"
                  update_task_field "$sel_id" "session_uid" "$dash_session_uid"
                  tmux_select_window "$sel_id"
                  ;;
                paused)
                  if tmux_window_exists "$sel_id" && ! _tmux_claude_alive "$sel_id"; then
                    tmux_kill_window "$sel_id"
                  fi
                  if ! tmux_window_exists "$sel_id"; then
                    local wt_mode_paused="${_task_wtmode[$sel_id]}"
                    local resume_cmd
                    resume_cmd=$(_build_claude_resume_cmd "$sel_id")
                    if [[ "$wt_mode_paused" == "none" ]]; then
                      _tmux_launch_claude "$sel_id" "$sel_rpath" "$resume_cmd"
                    else
                      local wt_p
                      wt_p=$(find_worktree_path "$sel_id" "$sel_rpath")
                      [[ -n "$wt_p" ]] && _tmux_launch_claude "$sel_id" "$wt_p" "$resume_cmd"
                    fi
                  fi
                  update_task_field "$sel_id" "status" "active"
                  tmux_select_window "$sel_id"
                  ;;
                active|needs_review)
                  if tmux_window_exists "$sel_id" && ! _tmux_claude_alive "$sel_id"; then
                    tmux_kill_window "$sel_id"
                  fi
                  if ! tmux_window_exists "$sel_id"; then
                    local wt_mode_act="${_task_wtmode[$sel_id]}"
                    local resume_cmd
                    resume_cmd=$(_build_claude_resume_cmd "$sel_id")
                    if [[ "$wt_mode_act" == "none" ]]; then
                      _tmux_launch_claude "$sel_id" "$sel_rpath" "$resume_cmd"
                    else
                      local wt_a
                      wt_a=$(find_worktree_path "$sel_id" "$sel_rpath")
                      [[ -n "$wt_a" ]] && _tmux_launch_claude "$sel_id" "$wt_a" "$resume_cmd"
                    fi
                  fi
                  cursor_show
                  tmux_select_window "$sel_id"
                  cursor_hide
                  ;;
                done)
                  cursor_show; stty echo
                  local task_title_done="${_task_title[$sel_id]}"
                  echo ""
                  echo "${C_CYAN}Reopening '${sel_id}': ${task_title_done}${C_RESET}"
                  printf "${C_CYAN}Prompt for Claude (or Enter to continue previous session): ${C_RESET}"
                  local reopen_prompt=""
                  read -r reopen_prompt
                  stty -echo; cursor_hide
                  local dash_claude_cmd
                  if [[ -n "$reopen_prompt" ]]; then
                    local escaped="${reopen_prompt//\'/\'\\\'\'}"
                    dash_claude_cmd="claude --dangerously-skip-permissions '${escaped}'"
                  else
                    dash_claude_cmd=$(_build_claude_resume_cmd "$sel_id")
                  fi
                  _tmux_launch_claude "$sel_id" "$sel_rpath" "$dash_claude_cmd"
                  update_task_field "$sel_id" "status" "active"
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
        cron:*)
          # Cron Enter: attach to active run window, or show details
          local cid="${item#cron:}"
          local rdata="${_cron_run_data[$cid]:-}"
          if [[ -n "$rdata" ]]; then
            local rjob_id rstat recode rstart rsid rwin
            IFS=$'\x1e' read -r rjob_id rstat recode rstart rsid rwin <<< "$(echo -e "$rdata")"
            if [[ "$rstat" == "active" && -n "$rwin" ]] && tmux_window_exists "$rwin"; then
              cursor_show
              tmux_select_window "$rwin"
              cursor_hide
            elif [[ -n "$rsid" ]]; then
              local resume_win="resume-${cid}"
              local cjob_wdir
              cjob_wdir=$(cron_job_field "$rjob_id" "working_dir")
              local safe_wdir=${(q)cjob_wdir}
              ensure_tmux_session
              tmux_create_window "$resume_win" "zsh" "-c" \
                "cd ${safe_wdir} && claude --resume ${rsid}; zsh; tmux -L cloard-board select-window -t board:dashboard 2>/dev/null"
              cursor_show
              tmux_select_window "$resume_win"
              cursor_hide
            fi
          else
            # Scheduled job: show details
            cursor_show; stty echo
            echo ""
            local jname="${_cron_jobs[$cid]:-}"
            local jsched="${_cron_job_schedule[$cid]:-}"
            local jenabled="${_cron_job_enabled[$cid]:-}"
            echo "${C_BOLD}Cron Job: ${cid}${C_RESET}"
            echo "  name: ${jname}"
            echo "  schedule: ${jsched}"
            echo "  enabled: ${jenabled}"
            echo ""
            echo "${C_DIM}Press any key to return...${C_RESET}"
            read -rsk1 2>/dev/null || true
            stty -echo; cursor_hide
          fi
          ;;
      esac
      ;;

    $'\t') # Tab: jump cursor to next group/cron_group header
      local _ti
      for (( _ti=_list_cursor + 1; _ti <= max_idx; _ti++ )); do
        case "${_list_items[$_ti]:-}" in
          group:*|cron_group:*)
            _list_cursor=$_ti
            break
            ;;
        esac
      done
      ;;

    SHIFT_TAB) # Shift-Tab: jump cursor to previous group/cron_group header
      local _ti
      for (( _ti=_list_cursor - 1; _ti >= 0; _ti-- )); do
        case "${_list_items[$_ti]:-}" in
          group:*|cron_group:*)
            _list_cursor=$_ti
            break
            ;;
        esac
      done
      ;;

    D) # Toggle show done tasks
      if [[ "$_show_done" == "1" ]]; then
        _show_done=0
      else
        _show_done=1
      fi
      _list_needs_rebuild=1
      ;;

    b) # Toggle split view
      if [[ "${_split_active:-0}" == "1" ]]; then
        _split_close
      elif _list_get_selected_id; then
        _split_open "$_tid"
      fi
      ;;

    l) # Focus right pane (Claude session) when split is active
      if [[ "${_split_active:-0}" == "1" ]]; then
        tmux_cmd select-pane -t "board:dashboard.1" 2>/dev/null || true
      fi
      ;;

    ESC) # Escape
      if [[ "${_split_active:-0}" == "1" ]]; then
        _split_close
      else
        # Collapse current group if cursor is on a task within it
        local item="${_list_items[$_list_cursor]:-}"
        case "$item" in
          task:*)
            # Walk backward to find the parent group header
            local _ei
            for (( _ei=_list_cursor - 1; _ei >= 0; _ei-- )); do
              case "${_list_items[$_ei]:-}" in
                group:*)
                  local gname="${_list_items[$_ei]#group:}"
                  _list_group_collapsed[$gname]=1
                  _list_cursor=$_ei
                  _list_needs_rebuild=1
                  break
                  ;;
              esac
            done
            ;;
          cron:*)
            _list_group_collapsed[__cron]=1
            # Jump to the cron_group header
            local _ei
            for (( _ei=_list_cursor - 1; _ei >= 0; _ei-- )); do
              [[ "${_list_items[$_ei]:-}" == "cron_group:__cron" ]] && { _list_cursor=$_ei; break; }
            done
            _list_needs_rebuild=1
            ;;
        esac
      fi
      ;;

    *) return 1 ;; # Key not handled; fall through to shared handlers
  esac

  return 0
}
