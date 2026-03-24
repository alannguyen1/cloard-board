# ── Dashboard render helpers ───────────────────────────────────────────────────
# Pure render functions that append to _frame. They rely on zsh dynamic scoping
# to access variables declared local in cmd__dash_loop (snapshot arrays, nav
# state, terminal dimensions, border strings, etc.).

# Render the title/status bar at the top of the dashboard
_render_status_bar() {
  local title_str
  if [[ "$filter_mode" == "all" ]]; then
    title_str="  cloard-board -- All repos (${_total_task_count} tasks: ${_active_count} active, ${_review_count} needs review)"
  else
    local ft_cnt="${_repo_task_count[$filter_mode]:-0}"
    title_str="  cloard-board -- ${filter_mode} (${ft_cnt} tasks)"
  fi
  local _tpad="${(r:${cols}:)title_str}"
  _frame+="${C_BOLD}${C_BG_BLUE}${C_WHITE}${_tpad}${C_RESET}"
  _frame+=$'\n'
}

# Render the cron jobs section at the bottom of the board
_render_cron_row() {
  local cron_total=$(( ${_cron_col_cnt[__cron:0]:-0} + ${_cron_col_cnt[__cron:1]:-0} + ${_cron_col_cnt[__cron:2]:-0} ))

  # Cron section header
  local cron_hdr="[cron jobs] (${cron_total} items)"
  local _cron_w=$((cols - 2))
  [[ $_cron_w -lt 0 ]] && _cron_w=0
  if [[ $cron_row_selected -eq 1 && "$nav_mode" == "repo" ]]; then
    local _ch="> ${cron_hdr}"
    _frame+="${C_BOLD}${C_BG_BLUE}${C_WHITE}${(r:${cols}:)_ch}${C_RESET}"
  else
    local _ch="  ${cron_hdr}"
    _frame+="${C_BOLD}${(r:${cols}:)_ch}${C_RESET}"
  fi
  _frame+=$'\n'

  # Cron column headers (3 columns, using the 5-col layout width)
  local cron_col_w=$(( (cols - 2) / 4 ))
  local cron_card_inner=$(( cron_col_w - 4 ))
  local _cron_border=""
  for (( _i=0; _i<cron_card_inner; _i++ )); do _cron_border+="─"; done

  local cron_header_line=""
  for ci in {0..3}; do
    local ccc
    case $ci in
      0) ccc="$C_DIM" ;;
      1) ccc="$C_GREEN" ;;
      2) ccc="$C_YELLOW" ;;
      3) ccc="$C_CYAN" ;;
    esac
    local ccnt="${_cron_col_cnt[__cron:${ci}]:-0}"
    local chdr=$(printf "%s (%d)" "${CRON_COL_NAMES[$ci]}" "$ccnt")
    chdr=$(trunc "$chdr" "$cron_col_w")
    local chdr_sel=""
    if [[ $cron_row_selected -eq 1 && $ci -eq $cur_cron_col ]]; then
      chdr_sel="${C_BOLD}"
    fi
    cron_header_line+=$(printf "${chdr_sel}${ccc}%-${cron_col_w}s${C_RESET}" "$chdr")
  done
  _frame+="$cron_header_line"$'\n'

  # Cron cards: render up to max rows
  local cron_max=0
  for ci in {0..3}; do
    local cnt="${_cron_col_cnt[__cron:${ci}]:-0}"
    [[ $cnt -gt $cron_max ]] && cron_max=$cnt
  done
  local cron_visible=$((cron_max < 3 ? cron_max : 3))
  [[ $cron_visible -lt 1 ]] && cron_visible=0

  if [[ $cron_visible -gt 0 ]]; then
    for (( crow_idx=0; crow_idx<cron_visible; crow_idx++ )); do
      for line_no in {0..4}; do
        local output=""
        for ci in {0..3}; do
          local ccc
          case $ci in
            0) ccc="$C_DIM" ;;
            1) ccc="$C_GREEN" ;;
            2) ccc="$C_YELLOW" ;;
            3) ccc="$C_CYAN" ;;
          esac
          _get_cron_item_at "$ci" "$crow_idx"
          local item_id="$_tid"

          if [[ -z "$item_id" ]]; then
            output+=$(printf '%-*s' "$cron_col_w" "")
          else
            local is_selected=false
            if [[ $cron_row_selected -eq 1 && "$nav_mode" == "card" ]]; then
              local ccrow="${cur_cron_card_row[${ci}]:-0}"
              [[ $ci -eq $cur_cron_col && $ccrow -eq $crow_idx ]] && is_selected=true
            fi

            local sel_prefix=" "
            local sel_color=""
            if $is_selected; then
              sel_prefix=">"
              sel_color="${C_BOLD}${C_BG_BLUE}${C_WHITE}"
            fi

            local cell=""
            case $ci in
              0)  # Scheduled: show job info
                local jname="${_cron_jobs[$item_id]:-}"
                local jsched="${_cron_job_schedule[$item_id]:-}"
                local jenabled="${_cron_job_enabled[$item_id]:-true}"
                local sched_line="$jsched"
                local sched_color="${ccc}${C_DIM}"
                if [[ "$jenabled" != "true" ]]; then
                  sched_line="disabled"
                  sched_color="${C_RED}"
                fi
                case $line_no in
                  0) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc}${sel_prefix}┌%s┐${C_RESET}" "$_cron_border") ;;
                  1) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} │${C_BOLD}%-*s${C_RESET}${ccc}│${C_RESET}" "$cron_card_inner" " $(trunc "$item_id" $((cron_card_inner-1)))") ;;
                  2) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} │%-*s│${C_RESET}" "$cron_card_inner" " $(trunc "$jname" $((cron_card_inner-1)))") ;;
                  3) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${sched_color} │%-*s│${C_RESET}" "$cron_card_inner" " $(trunc "$sched_line" $((cron_card_inner-1)))") ;;
                  4) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} └%s┘${C_RESET}" "$_cron_border") ;;
                esac
                ;;
              1)  # Active: show run info
                local rdata="${_cron_run_data[$item_id]:-}"
                local rjob_id rstat recode rstart rsid rwin rcompleted
                IFS=$'\x1e' read -r rjob_id rstat recode rstart rsid rwin rcompleted <<< "$(echo -e "$rdata")"
                local rjname="${_cron_jobs[$rjob_id]:-$rjob_id}"
                case $line_no in
                  0) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc}${sel_prefix}┌%s┐${C_RESET}" "$_cron_border") ;;
                  1) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} │${C_BOLD}%-*s${C_RESET}${ccc}│${C_RESET}" "$cron_card_inner" " $(trunc "$item_id" $((cron_card_inner-1)))") ;;
                  2) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} │%-*s│${C_RESET}" "$cron_card_inner" " $(trunc "$rjname" $((cron_card_inner-1)))") ;;
                  3) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${C_GREEN} │%-*s│${C_RESET}" "$cron_card_inner" " $(trunc "${TUI_GLYPH_ACTIVE} running" $((cron_card_inner-1)))") ;;
                  4) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} └%s┘${C_RESET}" "$_cron_border") ;;
                esac
                ;;
              2)  # Needs Review: show run info
                local rdata="${_cron_run_data[$item_id]:-}"
                local rjob_id rstat recode rstart rsid rwin rcompleted
                IFS=$'\x1e' read -r rjob_id rstat recode rstart rsid rwin rcompleted <<< "$(echo -e "$rdata")"
                local rjname="${_cron_jobs[$rjob_id]:-$rjob_id}"
                local exit_info="exit ${recode}"
                if [[ -n "${rcompleted:-}" ]]; then
                  _time_ago "$rcompleted"
                  [[ -n "$_tago" ]] && exit_info="${exit_info} ${_tago}"
                fi
                case $line_no in
                  0) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc}${sel_prefix}┌%s┐${C_RESET}" "$_cron_border") ;;
                  1) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} │${C_BOLD}%-*s${C_RESET}${ccc}│${C_RESET}" "$cron_card_inner" " $(trunc "$item_id" $((cron_card_inner-1)))") ;;
                  2) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} │%-*s│${C_RESET}" "$cron_card_inner" " $(trunc "$rjname" $((cron_card_inner-1)))") ;;
                  3) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${C_YELLOW} │%-*s│${C_RESET}" "$cron_card_inner" " $(trunc "$exit_info" $((cron_card_inner-1)))") ;;
                  4) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} └%s┘${C_RESET}" "$_cron_border") ;;
                esac
                ;;
              3)  # Done: show reviewed run info
                local rdata="${_cron_run_data[$item_id]:-}"
                local rjob_id rstat recode rstart rsid rwin rcompleted
                IFS=$'\x1e' read -r rjob_id rstat recode rstart rsid rwin rcompleted <<< "$(echo -e "$rdata")"
                local rjname="${_cron_jobs[$rjob_id]:-$rjob_id}"
                local exit_info="exit ${recode}"
                case $line_no in
                  0) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc}${sel_prefix}┌%s┐${C_RESET}" "$_cron_border") ;;
                  1) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} │${C_BOLD}%-*s${C_RESET}${ccc}│${C_RESET}" "$cron_card_inner" " $(trunc "$item_id" $((cron_card_inner-1)))") ;;
                  2) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} │%-*s│${C_RESET}" "$cron_card_inner" " $(trunc "$rjname" $((cron_card_inner-1)))") ;;
                  3) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${C_CYAN} │%-*s│${C_RESET}" "$cron_card_inner" " $(trunc "${TUI_GLYPH_DONE} $exit_info" $((cron_card_inner-1)))") ;;
                  4) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} └%s┘${C_RESET}" "$_cron_border") ;;
                esac
                ;;
            esac

            output+="$cell"
            local cell_visual_len=$((cron_card_inner + 4))
            local pad=$(( cron_col_w - cell_visual_len ))
            [[ $pad -gt 0 ]] && output+=$(printf '%*s' "$pad" "")
          fi
        done
        _frame+="$output"$'\n'
      done
    done
  fi

  # Throttled stale-run cleanup (every 60s)
  local _now_epoch
  _now_epoch=$(date +%s)
  if [[ $((_now_epoch - _last_archive_check)) -ge 60 ]]; then
    _archive_stale_cron_runs 2>/dev/null &
    _last_archive_check=$_now_epoch
  fi
}

# Resolve the current footer mode from dashboard state.
_footer_mode_key() {
  if [[ "${_view_mode:-kanban}" == "list" ]]; then
    if [[ ${_split_active:-0} -eq 1 ]]; then
      printf '%s' 'list_split'
    else
      printf '%s' 'list_full'
    fi
  elif [[ ${cron_row_selected:-0} -eq 1 ]]; then
    printf '%s' 'cron'
  elif [[ "${filter_mode:-all}" == 'all' ]]; then
    if [[ "${nav_mode:-repo}" == 'repo' ]]; then
      printf '%s' 'kanban_repo'
    else
      printf '%s' 'kanban_card'
    fi
  else
    printf '%s' 'kanban_filtered'
  fi
}

# Return the footer text for a given mode/variant combination.
_footer_variant_text() {
  local mode="$1" variant="$2"
  case "${mode}:${variant}" in
    list_split:full)
      printf '%s' '  j/k: nav  Enter/l: focus  Ctrl-F: toggle  F: fullscreen  </> status  r: reopen  t: rename  s: shell  x: done  d: show done  H: history  Tab: filter  b: undock  q: quit'
      ;;
    list_split:compact)
      printf '%s' 'j/k nav  Enter/l focus  Ctrl-F toggle  F fullscreen  Tab filter  b undock  q quit'
      ;;
    list_split:minimal)
      printf '%s' 'j/k nav  Enter/l focus  b undock  q quit'
      ;;

    list_full:full)
      printf '%s' '  j/k: nav  Tab: filter  Enter: open  </> status  :/" reorder  r: reopen  t: rename  s: shell  x: done  d: show done  H: history  c: new  b: dock  F: fullscreen  v: kanban  q: quit'
      ;;
    list_full:compact)
      printf '%s' 'j/k nav  Enter open  Tab filter  b dock  F fullscreen  v kanban  q quit'
      ;;
    list_full:minimal)
      printf '%s' 'j/k nav  Enter open  b dock  q quit'
      ;;

    cron:full)
      printf '%s' '  j/k: cards  h/l: cols  Enter: open/resume  x: review/done  c: create  D: delete  Esc: back  v: list  q: quit'
      ;;
    cron:compact)
      printf '%s' 'Enter open  x review/done  c create  q quit'
      ;;
    cron:minimal)
      printf '%s' 'Enter open  q quit'
      ;;

    kanban_repo:full)
      printf '%s' '  Tab: filter  j/k: repos  Enter: expand/zoom  Esc: collapse  c: new  S: import  R: add repo  v: list  q: quit'
      ;;
    kanban_repo:compact)
      printf '%s' 'j/k repos  Enter zoom  Tab filter  v list  q quit'
      ;;
    kanban_repo:minimal)
      printf '%s' 'j/k repos  Enter zoom  q quit'
      ;;

    kanban_card:full)
      printf '%s' '  j/k: scroll  :/" reorder  Esc: repos  c: new  S: import  t: rename  H: history  R: add repo  v: list  q: quit'
      ;;
    kanban_card:compact|kanban_filtered:compact)
      printf '%s' 'j/k cards  Enter open  c new  v list  q quit'
      ;;
    kanban_card:minimal|kanban_filtered:minimal)
      printf '%s' 'j/k cards  Enter open  q quit'
      ;;

    kanban_filtered:full)
      printf '%s' '  Tab: filter  j/k: cards  Enter: open  r: reopen  </> move  :/" reorder  c: new  t: rename  s: shell  x: done  d: show done  H: history  v: list  q: quit'
      ;;
    *)
      printf '%s' ''
      ;;
  esac
}

_footer_text_lines() {
  local text="$1"
  local width="${2:-${cols:-1}}"
  (( width > 0 )) || width=1
  [[ -n "$text" ]] || {
    printf '%s' '1'
    return 0
  }
  local lines=$(( (${#text} + width - 1) / width ))
  (( lines < 1 )) && lines=1
  printf '%s' "$lines"
}

_footer_print_padded_lines() {
  local text="$1"
  local width="${2:-${cols:-1}}"
  (( width > 0 )) || width=1

  local remaining="$text"
  local line=""
  while true; do
    if [[ ${#remaining} -gt $width ]]; then
      line="${remaining[1,$width]}"
      remaining="${remaining[$((width + 1)),-1]}"
    else
      line="$remaining"
      remaining=""
    fi

    printf "${C_DIM}%-${width}s${C_RESET}" "$line"
    [[ -n "$remaining" ]] || break
    printf '\n'
  done
}

# Choose the responsive footer text and matching line count for the current
# dashboard mode and pane width.
_footer_select_layout() {
  local mode full compact minimal
  local -i full_lines compact_lines minimal_lines

  mode=$(_footer_mode_key)
  full=$(_footer_variant_text "$mode" full)
  compact=$(_footer_variant_text "$mode" compact)
  minimal=$(_footer_variant_text "$mode" minimal)

  full_lines=$(_footer_text_lines "$full")
  if (( full_lines <= 1 )); then
    _footer_text="$full"
    _footer_lines=$full_lines
    return 0
  fi

  compact_lines=$(_footer_text_lines "$compact")
  if (( compact_lines <= 2 )); then
    _footer_text="$compact"
    _footer_lines=$compact_lines
    return 0
  fi

  minimal_lines=$(_footer_text_lines "$minimal")
  _footer_text="$minimal"
  _footer_lines=$minimal_lines
}

# Render the key-hints footer bar at the bottom of the screen
_render_footer() {
  [[ -n "${_footer_text:-}" ]] || _footer_select_layout
  move_to "$((rows - ${_footer_lines:-1} + 1))" 1
  _footer_print_padded_lines "${_footer_text:-}" "${cols:-1}"
}
