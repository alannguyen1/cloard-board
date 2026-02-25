# ── Dashboard snapshot (single jq call per frame) ────────────────────────────

# Snapshot all task data into associative + indexed arrays
# Relies on caller declaring the arrays (see cmd__dash_loop)
_snapshot_tasks() {
  _task_status=()
  _task_title=()
  _task_pr=()
  _task_claude=()
  _task_wtmode=()
  _task_repo=()
  _repo_names=()
  _repo_paths=()
  _repo_types=()
  _repo_stale=()
  _repo_task_count=()
  _repo_cols=()
  _repo_col_cnt=()
  _total_task_count=0
  _active_count=0
  _review_count=0

  # Cron data
  _cron_jobs=()           # id -> name
  _cron_job_enabled=()    # id -> true/false
  _cron_job_schedule=()   # id -> schedule_desc
  _cron_run_data=()       # run_id -> "cron_job_id\x1estatus\x1eexit_code\x1estarted_at\x1esession_id\x1etmux_window"
  _cron_col_ids=()        # __cron:N -> space-separated IDs
  _cron_col_cnt=()        # __cron:N -> count
  _has_cron_data=false
  for _ci in {0..3}; do
    _cron_col_ids["__cron:${_ci}"]=""
    _cron_col_cnt["__cron:${_ci}"]=0
  done

  local _snap
  _snap=$(jq -r '
    ("H\u001e" + (.next_task_id | tostring) + "\u001e" + (.repos | length | tostring) + "\u001e" + (.tasks | length | tostring)),
    (.repos[] | "R\u001e" + .name + "\u001e" + .path + "\u001e" + (.type // "git") + "\u001e" + (if .archived == true then "1" else "0" end)),
    (.tasks[] | "T\u001e" + .id + "\u001e" + .status + "\u001e" + (.title // "") + "\u001e" + (.pr_url // "") + "\u001e" + (.claude_status // "") + "\u001e" + (.worktree_mode // "worktree") + "\u001e" + (.repo // "")),
    (.cron_jobs[]? | "CJ\u001e" + .id + "\u001e" + .name + "\u001e" + (if .enabled then "true" else "false" end) + "\u001e" + (.schedule_desc // "")),
    (.cron_runs[]? | select(.status == "active" or .status == "needs_review" or .status == "reviewed") | "CR\u001e" + .run_id + "\u001e" + .cron_job_id + "\u001e" + .status + "\u001e" + (.exit_code | tostring) + "\u001e" + (.started_at // "") + "\u001e" + (.session_id // "") + "\u001e" + (.tmux_window // ""))
  ' "$GLOBAL_STATE" 2>/dev/null) || return 0

  while IFS=$'\x1e' read -r _type _f1 _f2 _f3 _f4 _f5 _f6 _f7; do
    case "$_type" in
      H)
        _total_task_count="$_f3"
        ;;
      R)
        # _f1=name, _f2=path, _f3=type, _f4=archived
        if [[ "$_f4" != "1" ]]; then
          _repo_names+=("$_f1")
          _repo_paths[$_f1]="$_f2"
          _repo_types[$_f1]="$_f3"
          if [[ ! -d "$_f2" ]]; then
            _repo_stale[$_f1]="1"
          fi
          _repo_task_count[$_f1]=0
          for _ci in {0..3}; do
            _repo_cols["${_f1}:${_ci}"]=""
            _repo_col_cnt["${_f1}:${_ci}"]=0
          done
        fi
        ;;
      T)
        # _f1=id, _f2=status, _f3=title, _f4=pr_url, _f5=claude_status, _f6=worktree_mode, _f7=repo
        _task_status[$_f1]="$_f2"
        _task_title[$_f1]="$_f3"
        _task_pr[$_f1]="$_f4"
        _task_claude[$_f1]="$_f5"
        _task_wtmode[$_f1]="$_f6"
        _task_repo[$_f1]="$_f7"

        [[ "$_f2" == "active" ]] && _active_count=$((_active_count + 1))
        [[ "$_f2" == "needs_review" ]] && _review_count=$((_review_count + 1))

        # Assign to repo column
        local _col_idx
        case "$_f2" in
          pending|paused) _col_idx=0 ;;
          active)         _col_idx=1 ;;
          needs_review)   _col_idx=2 ;;
          done)           _col_idx=3 ;;
          *) continue ;;
        esac

        local _key="${_f7}:${_col_idx}"
        if [[ -n "${_repo_cols[$_key]:-}" ]]; then
          if [[ "$_f5" == "waiting" ]]; then
            # Waiting tasks float to top of the column
            _repo_cols[$_key]="${_f1} ${_repo_cols[$_key]}"
          else
            _repo_cols[$_key]="${_repo_cols[$_key]} ${_f1}"
          fi
        else
          _repo_cols[$_key]="${_f1}"
        fi
        _repo_col_cnt[$_key]=$(( ${_repo_col_cnt[$_key]:-0} + 1 ))
        _repo_task_count[$_f7]=$(( ${_repo_task_count[$_f7]:-0} + 1 ))
        ;;
      CJ)
        # _f1=id, _f2=name, _f3=enabled, _f4=schedule_desc
        _cron_jobs[$_f1]="$_f2"
        _cron_job_enabled[$_f1]="$_f3"
        _cron_job_schedule[$_f1]="$_f4"
        _has_cron_data=true
        # All jobs go to col 0 (Scheduled), regardless of enabled state
        local _ck="__cron:0"
        if [[ -n "${_cron_col_ids[$_ck]:-}" ]]; then
          _cron_col_ids[$_ck]="${_cron_col_ids[$_ck]} $_f1"
        else
          _cron_col_ids[$_ck]="$_f1"
        fi
        _cron_col_cnt[$_ck]=$(( ${_cron_col_cnt[$_ck]:-0} + 1 ))
        ;;
      CR)
        # _f1=run_id, _f2=cron_job_id, _f3=status, _f4=exit_code, _f5=started_at, _f6=session_id, _f7=tmux_window
        _cron_run_data[$_f1]="${_f2}\x1e${_f3}\x1e${_f4}\x1e${_f5}\x1e${_f6}\x1e${_f7}"
        _has_cron_data=true
        local _cron_col
        if [[ "$_f3" == "active" ]]; then
          _cron_col=1
        elif [[ "$_f3" == "needs_review" ]]; then
          _cron_col=2
        elif [[ "$_f3" == "reviewed" ]]; then
          _cron_col=3
        else
          continue
        fi
        local _ck="__cron:${_cron_col}"
        if [[ -n "${_cron_col_ids[$_ck]:-}" ]]; then
          _cron_col_ids[$_ck]="${_cron_col_ids[$_ck]} $_f1"
        else
          _cron_col_ids[$_ck]="$_f1"
        fi
        _cron_col_cnt[$_ck]=$(( ${_cron_col_cnt[$_ck]:-0} + 1 ))
        ;;
    esac
  done <<< "$_snap"
}

# Get task ID at a position within a repo column
_get_repo_task_at() {
  local rname="$1" col="$2" row="$3"
  local ids_str="${_repo_cols[${rname}:${col}]:-}"
  [[ -n "$ids_str" ]] || { _tid=""; return; }
  local -a ids_arr=(${(s: :)ids_str})
  _tid="${ids_arr[$row]:-}"
}

# Get cron item ID at a position within a cron column
_get_cron_item_at() {
  local col="$1" row="$2"
  local ids_str="${_cron_col_ids[__cron:${col}]:-}"
  [[ -n "$ids_str" ]] || { _tid=""; return; }
  local -a ids_arr=(${(s: :)ids_str})
  _tid="${ids_arr[$row]:-}"
}

# Get selected cron item ID for current navigation state
_get_selected_cron_id() {
  _tid=""
  local cnt="${_cron_col_cnt[__cron:${cur_cron_col}]:-0}"
  [[ $cnt -gt 0 ]] || return 1
  local crow="${cur_cron_card_row[${cur_cron_col}]:-0}"
  _get_cron_item_at "$cur_cron_col" "$crow"
  [[ -n "$_tid" ]] || return 1
}

# Get selected task ID for current navigation state
_get_selected_id() {
  _tid=""
  local rname
  if [[ "$filter_mode" != "all" ]]; then
    rname="$filter_mode"
  else
    [[ ${#_repo_names[@]} -gt 0 ]] || return 1
    [[ $cur_repo_idx -lt ${#_repo_names[@]} ]] || return 1
    rname="${_repo_names[$cur_repo_idx]}"
  fi
  [[ -n "$rname" ]] || return 1

  local cnt="${_repo_col_cnt[${rname}:${cur_col}]:-0}"
  [[ $cnt -gt 0 ]] || return 1

  local crow="${cur_card_row[${rname}:${cur_col}]:-0}"
  _get_repo_task_at "$rname" "$cur_col" "$crow"
  [[ -n "$_tid" ]] || return 1
}

