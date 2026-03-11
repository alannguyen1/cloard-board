# ── List mode render + key handler ────────────────────────────────────────────
# Pure render functions that append to _frame. They rely on zsh dynamic scoping
# to access variables declared local in cmd__dash_loop.

# ── Height / offset helpers ──────────────────────────────────────────────────

# Return the display height of item at index $1. Result in _lih (avoids subshell).
_list_item_height() {
  local item="${_list_items[$1]:-}"
  case "$item" in
    group:*|cron_group:*) _lih=1 ;;
    task:*|cron:*)        _lih=1 ;;
    *)                    _lih=1 ;;
  esac
}

# Compute the content-line offset of item at index $1 by summing heights of all
# preceding items. Result in _lcl (avoids subshell).
_list_content_line_of() {
  _lcl=$1
}

# ── Scroll management ───────────────────────────────────────────────────────

# Ensure the cursor item is within the visible viewport. Adjusts _list_scroll_top.
_list_adjust_scroll() {
  local viewport_height=${_viewport_height:-$((rows - 3))}
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
  for _ci in {0..3}; do
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

# ── Task card (1 line) ──────────────────────────────────────────────────────

# Render a single-line task card. Appends to _frame.
# Format: > ● Fix authentication bug          ⚙ #42
# $1 = task_id, $2 = available width, $3 = 1 if selected
_render_list_task_card() {
  local task_id="$1"
  local width="$2"
  local is_selected="$3"

  local title="${_task_title[$task_id]:-}"
  local tstatus="${_task_status[$task_id]:-}"
  local claude="${_task_claude[$task_id]:-}"
  local pr="${_task_pr[$task_id]:-}"

  # Single-char status badge
  local badge_char="" badge_color=""
  case "$tstatus" in
    active)       badge_char="●"; badge_color="$C_GREEN" ;;
    needs_review) badge_char="◆"; badge_color="$C_YELLOW" ;;
    pending)      badge_char="○"; badge_color="$C_DIM" ;;
    paused)       badge_char="◫"; badge_color="$C_CYAN" ;;
    done)         badge_char="✓"; badge_color="$C_DIM" ;;
  esac

  # Right-side metadata: claude indicator + PR short
  local right_meta=""
  [[ "$claude" == "working" ]] && right_meta="⚙"
  [[ "$claude" == "waiting" ]] && right_meta="○"
  if [[ -n "$pr" ]]; then
    local pr_short
    pr_short=$(echo "$pr" | command grep -oE '#[0-9]+' 2>/dev/null || echo "PR")
    [[ -n "$right_meta" ]] && right_meta+=" "
    right_meta+="$pr_short"
  fi
  # Add spacing if we have right metadata
  [[ -n "$right_meta" ]] && right_meta="  ${right_meta}"

  local prefix=" "
  local sel_on="" sel_off=""
  if [[ "$is_selected" == "1" ]]; then
    prefix=">"
    sel_on="${C_BOLD}${C_BG_BLUE}${C_WHITE}"
    sel_off="${C_RESET}"
  fi

  # Layout: prefix(1) space(1) badge(1) space(1) title(fill) right_meta
  local fixed_left=4
  local right_len=${#right_meta}
  local title_max=$((width - fixed_left - right_len))
  [[ $title_max -lt 1 ]] && title_max=1
  local title_str
  title_str=$(trunc "$title" "$title_max")

  local title_w=$((width - fixed_left - right_len))
  [[ $title_w -lt 0 ]] && title_w=0

  if [[ "$is_selected" == "1" ]]; then
    _frame+="${sel_on}${prefix} ${badge_char} ${(r:$title_w:)title_str}${right_meta}${sel_off}"
  else
    _frame+="${prefix} ${badge_color}${badge_char}${C_RESET} ${(r:$title_w:)title_str}${C_DIM}${right_meta}${C_RESET}"
  fi
  _frame+=$'\n'
}

# ── Cron card (1 line) ──────────────────────────────────────────────────────

# Render a single-line cron card. Appends to _frame.
# Scheduled: "  ○ morning-routine              every 30m"
# Active:    "  ● morning-routine              ● running"
# Review:    "  ◆ morning-routine              ◆ review"
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

  # Determine if this is a job (col 0) or a run (col 1/2/3)
  local rdata="${_cron_run_data[$cron_id]:-}"

  local cron_name="" right_meta="" right_color=""
  local badge_char="" badge_color=""

  if [[ -z "$rdata" ]]; then
    # Scheduled cron job
    cron_name="${_cron_jobs[$cron_id]:-$cron_id}"
    local jsched="${_cron_job_schedule[$cron_id]:-}"
    local jenabled="${_cron_job_enabled[$cron_id]:-true}"
    if [[ "$jenabled" != "true" ]]; then
      badge_char="⊘"; badge_color="$C_RED"
      right_meta="disabled"
      right_color="$C_RED"
    elif [[ -n "$jsched" ]]; then
      badge_char="○"; badge_color="$C_DIM"
      right_meta="$jsched"
      right_color="$C_DIM"
    else
      badge_char="○"; badge_color="$C_DIM"
      right_meta="scheduled"
      right_color="$C_DIM"
    fi
  else
    # Cron run
    local rjob_id rstat recode rstart rsid rwin
    IFS=$'\x1e' read -r rjob_id rstat recode rstart rsid rwin <<< "$(echo -e "$rdata")"
    cron_name="${_cron_jobs[$rjob_id]:-$rjob_id}"
    case "$rstat" in
      active)       badge_char="●"; badge_color="$C_GREEN";  right_meta="● running";  right_color="$C_GREEN" ;;
      needs_review) badge_char="◆"; badge_color="$C_YELLOW"; right_meta="◆ review";   right_color="$C_YELLOW" ;;
      reviewed)     badge_char="✓"; badge_color="$C_CYAN";   right_meta="✓ reviewed";  right_color="$C_CYAN" ;;
      *)            badge_char="○"; badge_color="$C_DIM";     right_meta="$rstat";      right_color="$C_DIM" ;;
    esac
  fi

  # Layout: prefix(1) space(1) badge(1) space(1) name(fill) "  " right_meta
  local fixed_left=4
  local right_str="  ${right_meta}"
  local right_len=${#right_str}
  local name_w=$((width - fixed_left - right_len))
  [[ $name_w -lt 1 ]] && name_w=1
  local name_str
  name_str=$(trunc "$cron_name" "$name_w")

  if [[ "$is_selected" == "1" ]]; then
    _frame+="${sel_on}${prefix} ${badge_char} ${(r:$name_w:)name_str}${right_str}${sel_off}"
  else
    _frame+="${prefix} ${badge_color}${badge_char}${C_RESET} ${(r:$name_w:)name_str}${right_color}${right_str}${C_RESET}"
  fi
  _frame+=$'\n'
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
  local viewport_height=${_viewport_height:-$((rows - 3))}
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

# ── Sidebar task card (compact, single-line) ─────────────────────────────────

# Render a single-line sidebar task card. No task ID or PR; sidebar is narrow.
# Format: > ● Fix auth bug     ⚙
# $1 = task_id, $2 = available width, $3 = 1 if selected
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

  # Layout: prefix(1) space(1) badge(1) space(1) title(fill) claude_char
  local fixed=4
  local cc_len=${#claude_char}
  local title_max=$((width - fixed - cc_len))
  [[ $title_max -lt 1 ]] && title_max=1
  local title_str
  title_str=$(trunc "$title" "$title_max")
  local title_w=$((width - fixed - cc_len))
  [[ $title_w -lt 0 ]] && title_w=0

  if [[ "$is_selected" == "1" ]]; then
    _frame+="${sel_on}${prefix} ${badge_char} ${(r:$title_w:)title_str}${claude_char}${sel_off}"
  else
    _frame+="${prefix} ${badge_color}${badge_char}${C_RESET} ${(r:$title_w:)title_str}${C_DIM}${claude_char}${C_RESET}"
  fi
  _frame+=$'\n'
}

# ── Sidebar list renderer (split-pane mode) ──────────────────────────────────

# Render the list as a narrow sidebar. Same logic as _render_list_full but
# uses the narrower pane width and omits the scrollbar.
_render_list_sidebar() {
  local sidebar_w="${1:-$cols}"
  local viewport_height=${_viewport_height:-$((rows - 3))}
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

# Get the kanban-column-equivalent for a cron item selected in list mode.
# Sets _list_cron_col: 0=scheduled, 1=active, 2=needs_review, 3=reviewed.
# Returns 1 if not a cron item.
_list_get_cron_col() {
  local item="${_list_items[$_list_cursor]:-}"
  [[ "$item" != cron:* ]] && return 1
  local cid="${item#cron:}"
  local rdata="${_cron_run_data[$cid]:-}"
  if [[ -z "$rdata" ]]; then
    _list_cron_col=0  # Scheduled job
  else
    local rjob_id rstat recode rstart rsid rwin
    IFS=$'\x1e' read -r rjob_id rstat recode rstart rsid rwin <<< "$(echo -e "$rdata")"
    case "$rstat" in
      active)       _list_cron_col=1 ;;
      needs_review) _list_cron_col=2 ;;
      reviewed)     _list_cron_col=3 ;;
      *)            _list_cron_col=0 ;;
    esac
  fi
  return 0
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
          local repo_name="${_task_repo[$sel_id]}"
          if [[ -n "${_repo_stale[$repo_name]:-}" ]]; then
            cursor_show; stty echo
            echo ""
            echo "${C_RED}Repo path not found. Run: cloard-board repo update-path ${repo_name} <new-path>${C_RESET}"
            sleep 2
            stty -echo; cursor_hide
          elif [[ "${_split_active:-0}" == "1" ]]; then
            if [[ "$sel_id" != "$_split_task_id" ]]; then
              _split_switch_session "$sel_id"
            fi
            # Keep focus on sidebar (pane 0); user presses l to move to Claude pane
          else
            _split_open "$sel_id"
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

    $'\t') # Tab: cycle repo filter forward (matches kanban Tab behavior)
      local total_filters=$(( ${#_repo_names[@]} + 1 ))
      filter_idx=$(( (filter_idx + 1) % total_filters ))
      if [[ $filter_idx -eq 0 ]]; then
        filter_mode="all"
        # Expand all groups
        _list_group_collapsed=()
      else
        filter_mode="${_repo_names[$((filter_idx - 1))]}"
        # Collapse all groups except the selected repo; expand that one
        local _tf_rn
        for _tf_rn in "${_repo_names[@]}"; do
          _list_group_collapsed[$_tf_rn]=1
        done
        unset "_list_group_collapsed[$filter_mode]"
        _list_group_collapsed[__cron]=1
        # Move cursor to that repo's group header
        local _tf_i
        for (( _tf_i=0; _tf_i<${#_list_items[@]}; _tf_i++ )); do
          [[ "${_list_items[$_tf_i]}" == "group:${filter_mode}" ]] && { _list_cursor=$_tf_i; break; }
        done
      fi
      _list_needs_rebuild=1
      ;;

    SHIFT_TAB) # Shift-Tab: cycle repo filter backward
      local total_filters=$(( ${#_repo_names[@]} + 1 ))
      filter_idx=$(( (filter_idx - 1 + total_filters) % total_filters ))
      if [[ $filter_idx -eq 0 ]]; then
        filter_mode="all"
        _list_group_collapsed=()
      else
        filter_mode="${_repo_names[$((filter_idx - 1))]}"
        local _tf_rn
        for _tf_rn in "${_repo_names[@]}"; do
          _list_group_collapsed[$_tf_rn]=1
        done
        unset "_list_group_collapsed[$filter_mode]"
        _list_group_collapsed[__cron]=1
        local _tf_i
        for (( _tf_i=0; _tf_i<${#_list_items[@]}; _tf_i++ )); do
          [[ "${_list_items[$_tf_i]}" == "group:${filter_mode}" ]] && { _list_cursor=$_tf_i; break; }
        done
      fi
      _list_needs_rebuild=1
      ;;

    D) # Delete scheduled cron job
      local _d_item="${_list_items[$_list_cursor]:-}"
      if [[ "$_d_item" == cron:* ]]; then
        local _d_cid="${_d_item#cron:}"
        local _d_rdata="${_cron_run_data[$_d_cid]:-}"
        if [[ -z "$_d_rdata" ]]; then
          cursor_show
          stty echo
          echo ""
          (cmd_cron_remove "$_d_cid") 2>&1 || true
          stty -echo
          cursor_hide
          _list_needs_rebuild=1
        fi
      fi
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

    F) # Full-screen the Claude session (exits split view)
      if [[ "${_split_active:-0}" == "1" && -n "${_split_task_id:-}" ]]; then
        local fs_task_id="$_split_task_id"
        _split_close
        tmux_select_window "$fs_task_id"
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

    ':') # Move task up: swap with previous same-status/same-repo task
      local _r_item="${_list_items[$_list_cursor]:-}"
      if [[ "$_r_item" == task:* ]]; then
        local _r_id="${_r_item#task:}"
        local _r_repo="${_task_repo[$_r_id]:-}"
        local _r_st="${_task_status[$_r_id]:-}"
        # Find immediately previous task in same repo with same status
        local _r_i
        for (( _r_i=_list_cursor - 1; _r_i >= 0; _r_i-- )); do
          local _r_prev="${_list_items[$_r_i]:-}"
          [[ "$_r_prev" != task:* ]] && break  # Hit a group header; stop
          local _r_pid="${_r_prev#task:}"
          if [[ "${_task_repo[$_r_pid]:-}" == "$_r_repo" && "${_task_status[$_r_pid]:-}" == "$_r_st" ]]; then
            _swap_tasks_in_state "$_r_id" "$_r_pid"
            _list_cursor=$_r_i
            _list_needs_rebuild=1
            _list_follow_id="$_r_id"
            break
          fi
          break  # Only check the immediately previous task item
        done
      fi
      ;;

    '"') # Move task down: swap with next same-status/same-repo task
      local _r_item="${_list_items[$_list_cursor]:-}"
      if [[ "$_r_item" == task:* ]]; then
        local _r_id="${_r_item#task:}"
        local _r_repo="${_task_repo[$_r_id]:-}"
        local _r_st="${_task_status[$_r_id]:-}"
        local _r_max=$((${#_list_items[@]} - 1))
        local _r_i
        for (( _r_i=_list_cursor + 1; _r_i <= _r_max; _r_i++ )); do
          local _r_next="${_list_items[$_r_i]:-}"
          [[ "$_r_next" != task:* ]] && break  # Hit a group header; stop
          local _r_nid="${_r_next#task:}"
          if [[ "${_task_repo[$_r_nid]:-}" == "$_r_repo" && "${_task_status[$_r_nid]:-}" == "$_r_st" ]]; then
            _swap_tasks_in_state "$_r_id" "$_r_nid"
            _list_cursor=$_r_i
            _list_needs_rebuild=1
            _list_follow_id="$_r_id"
            break
          fi
          break  # Only check the immediately next task item
        done
      fi
      ;;

    *) return 1 ;; # Key not handled; fall through to shared handlers
  esac

  return 0
}
