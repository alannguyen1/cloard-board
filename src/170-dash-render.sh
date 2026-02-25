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
  _frame+=$(printf "${C_BOLD}${C_BG_BLUE}${C_WHITE}%-${cols}s${C_RESET}" "$title_str")
  _frame+=$'\n'
}

# Render the cron jobs section at the bottom of the board
_render_cron_row() {
  local cron_total=$(( ${_cron_col_cnt[__cron:0]:-0} + ${_cron_col_cnt[__cron:1]:-0} + ${_cron_col_cnt[__cron:2]:-0} ))

  # Cron section header
  local cron_hdr="[cron jobs] (${cron_total} items)"
  if [[ $cron_row_selected -eq 1 && "$nav_mode" == "repo" ]]; then
    _frame+=$(printf "${C_BOLD}${C_BG_BLUE}${C_WHITE}> %-$((cols-2))s${C_RESET}" "$cron_hdr")
  else
    _frame+=$(printf "${C_BOLD}  %-$((cols-2))s${C_RESET}" "$cron_hdr")
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
                local rjob_id rstat recode rstart rsid rwin
                IFS=$'\x1e' read -r rjob_id rstat recode rstart rsid rwin <<< "$(echo -e "$rdata")"
                local rjname="${_cron_jobs[$rjob_id]:-$rjob_id}"
                case $line_no in
                  0) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc}${sel_prefix}┌%s┐${C_RESET}" "$_cron_border") ;;
                  1) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} │${C_BOLD}%-*s${C_RESET}${ccc}│${C_RESET}" "$cron_card_inner" " $(trunc "$item_id" $((cron_card_inner-1)))") ;;
                  2) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} │%-*s│${C_RESET}" "$cron_card_inner" " $(trunc "$rjname" $((cron_card_inner-1)))") ;;
                  3) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${C_GREEN} │%-*s│${C_RESET}" "$cron_card_inner" " $(trunc "● running" $((cron_card_inner-1)))") ;;
                  4) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} └%s┘${C_RESET}" "$_cron_border") ;;
                esac
                ;;
              2)  # Needs Review: show run info
                local rdata="${_cron_run_data[$item_id]:-}"
                local rjob_id rstat recode rstart rsid rwin
                IFS=$'\x1e' read -r rjob_id rstat recode rstart rsid rwin <<< "$(echo -e "$rdata")"
                local rjname="${_cron_jobs[$rjob_id]:-$rjob_id}"
                local exit_info="exit ${recode}"
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
                local rjob_id rstat recode rstart rsid rwin
                IFS=$'\x1e' read -r rjob_id rstat recode rstart rsid rwin <<< "$(echo -e "$rdata")"
                local rjname="${_cron_jobs[$rjob_id]:-$rjob_id}"
                local exit_info="exit ${recode}"
                case $line_no in
                  0) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc}${sel_prefix}┌%s┐${C_RESET}" "$_cron_border") ;;
                  1) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} │${C_BOLD}%-*s${C_RESET}${ccc}│${C_RESET}" "$cron_card_inner" " $(trunc "$item_id" $((cron_card_inner-1)))") ;;
                  2) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${ccc} │%-*s│${C_RESET}" "$cron_card_inner" " $(trunc "$rjname" $((cron_card_inner-1)))") ;;
                  3) cell=$(printf "${sel_color:+$sel_color}${sel_color:- }${C_CYAN} │%-*s│${C_RESET}" "$cron_card_inner" " $(trunc "✓ $exit_info" $((cron_card_inner-1)))") ;;
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

# Render the key-hints footer bar at the bottom of the screen
_render_footer() {
  move_to "$((rows - 1))" 1
  if [[ $cron_row_selected -eq 1 ]]; then
    printf "${C_DIM}  j/k: cards  h/l: cols  Enter: open/resume  x: review/done  o: new cron  D: delete  Esc: back  q: quit${C_RESET}"
  elif [[ "$filter_mode" == "all" ]]; then
    if [[ "$nav_mode" == "repo" ]]; then
      printf "${C_DIM}  Tab: filter  j/k: repos  Enter: expand/zoom  Esc: collapse  o: new  S: import  R: add repo  q: quit${C_RESET}"
    else
      printf "${C_DIM}  j/k: scroll  :/\" reorder  Esc: repos  o: new  S: import  t: rename  R: add repo  q: quit${C_RESET}"
    fi
  else
    printf "${C_DIM}  Tab: filter  j/k: cards  Enter: open  r: reopen  </> move  :/\" reorder  o: new  t: rename  s: shell  d: diff  q: quit${C_RESET}"
  fi
}

