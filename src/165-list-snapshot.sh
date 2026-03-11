# ── List mode snapshot (flat ordered array from snapshot data) ─────────────────
# Builds _list_items[] for the list view. Relies on zsh dynamic scoping to
# access snapshot arrays and list state declared in cmd__dash_loop.

# Sort an array of task IDs by _task_status_at descending (newest first).
# ISO 8601 timestamps sort correctly as plain strings.
# Sets reply=() with the sorted result.
_sort_by_status_at() {
  reply=("${@}")
  local n=${#reply[@]}
  [[ $n -le 1 ]] && return
  local i j tmp
  for (( i=0; i<n-1; i++ )); do
    for (( j=i+1; j<n; j++ )); do
      if [[ "${_task_status_at[${reply[$i]}]:-}" < "${_task_status_at[${reply[$j]}]:-}" ]]; then
        tmp="${reply[$i]}"
        reply[$i]="${reply[$j]}"
        reply[$j]="$tmp"
      fi
    done
  done
}

_list_build_items() {
  _list_items=()

  # ── Repo task groups ────────────────────────────────────────────────────────
  local _lb_repo _lb_name
  for _lb_repo in "${_repo_names[@]}"; do
    _lb_name="$_lb_repo"
    _list_items+=("group:${_lb_name}")

    # Skip items if group is collapsed
    [[ "${_list_group_collapsed[$_lb_name]:-}" == "1" ]] && continue

    # Collect all task IDs across columns 0-3
    local -a _lb_all_ids=()
    local _lb_col _lb_ids_str
    for _lb_col in {0..3}; do
      _lb_ids_str="${_repo_cols[${_lb_repo}:${_lb_col}]:-}"
      [[ -z "$_lb_ids_str" ]] && continue
      local -a _lb_split=(${(s: :)_lb_ids_str})
      _lb_all_ids+=("${_lb_split[@]}")
    done

    [[ ${#_lb_all_ids[@]} -eq 0 ]] && continue

    # Compute priority for each task and emit in priority order (stable)
    local -a _lb_pri_0=() _lb_pri_1=() _lb_pri_2=() _lb_pri_3=() _lb_pri_4=() _lb_pri_5=() _lb_pri_6=()
    local _lb_tid _lb_st _lb_cl
    for _lb_tid in "${_lb_all_ids[@]}"; do
      _lb_st="${_task_status[$_lb_tid]:-}"
      _lb_cl="${_task_claude[$_lb_tid]:-}"

      case "$_lb_st" in
        active)
          if [[ "$_lb_cl" == "working" ]]; then
            _lb_pri_0+=("$_lb_tid")
          elif [[ "$_lb_cl" == "waiting" ]]; then
            _lb_pri_1+=("$_lb_tid")
          else
            _lb_pri_2+=("$_lb_tid")
          fi
          ;;
        needs_review)
          _lb_pri_3+=("$_lb_tid")
          ;;
        pending)
          _lb_pri_4+=("$_lb_tid")
          ;;
        paused)
          _lb_pri_5+=("$_lb_tid")
          ;;
        done)
          [[ "$_show_done" == "0" ]] && continue
          _lb_pri_6+=("$_lb_tid")
          ;;
      esac
    done

    # Sort each priority group by status_changed_at descending, then append
    local _lb_id
    local -a reply=()
    if [[ ${#_lb_pri_0[@]} -gt 1 ]]; then _sort_by_status_at "${_lb_pri_0[@]}"; _lb_pri_0=("${reply[@]}"); fi
    if [[ ${#_lb_pri_1[@]} -gt 1 ]]; then _sort_by_status_at "${_lb_pri_1[@]}"; _lb_pri_1=("${reply[@]}"); fi
    if [[ ${#_lb_pri_2[@]} -gt 1 ]]; then _sort_by_status_at "${_lb_pri_2[@]}"; _lb_pri_2=("${reply[@]}"); fi
    if [[ ${#_lb_pri_3[@]} -gt 1 ]]; then _sort_by_status_at "${_lb_pri_3[@]}"; _lb_pri_3=("${reply[@]}"); fi
    if [[ ${#_lb_pri_4[@]} -gt 1 ]]; then _sort_by_status_at "${_lb_pri_4[@]}"; _lb_pri_4=("${reply[@]}"); fi
    if [[ ${#_lb_pri_5[@]} -gt 1 ]]; then _sort_by_status_at "${_lb_pri_5[@]}"; _lb_pri_5=("${reply[@]}"); fi
    if [[ ${#_lb_pri_6[@]} -gt 1 ]]; then _sort_by_status_at "${_lb_pri_6[@]}"; _lb_pri_6=("${reply[@]}"); fi
    for _lb_id in "${_lb_pri_0[@]}"; do _list_items+=("task:${_lb_id}"); done
    for _lb_id in "${_lb_pri_1[@]}"; do _list_items+=("task:${_lb_id}"); done
    for _lb_id in "${_lb_pri_2[@]}"; do _list_items+=("task:${_lb_id}"); done
    for _lb_id in "${_lb_pri_3[@]}"; do _list_items+=("task:${_lb_id}"); done
    for _lb_id in "${_lb_pri_4[@]}"; do _list_items+=("task:${_lb_id}"); done
    for _lb_id in "${_lb_pri_5[@]}"; do _list_items+=("task:${_lb_id}"); done
    for _lb_id in "${_lb_pri_6[@]}"; do _list_items+=("task:${_lb_id}"); done
  done

  # ── Cron group ──────────────────────────────────────────────────────────────
  _list_items+=("cron_group:__cron")

  if [[ "${_list_group_collapsed[__cron]:-}" != "1" ]]; then
    # Cron items: active (col 1), then needs_review (col 2), then scheduled (col 0)
    local _lb_cron_col _lb_cron_ids
    for _lb_cron_col in 1 2 3 0; do
      _lb_cron_ids="${_cron_col_ids[__cron:${_lb_cron_col}]:-}"
      [[ -z "$_lb_cron_ids" ]] && continue
      local -a _lb_cron_arr=(${(s: :)_lb_cron_ids})
      local _lb_cid
      for _lb_cid in "${_lb_cron_arr[@]}"; do
        _list_items+=("cron:${_lb_cid}")
      done
    done
  fi

  # ── Follow cursor to tracked item ──────────────────────────────────────────
  if [[ -n "${_list_follow_id:-}" ]]; then
    local _lb_fi _lb_target="task:${_list_follow_id}"
    for (( _lb_fi=0; _lb_fi<${#_list_items[@]}; _lb_fi++ )); do
      if [[ "${_list_items[$_lb_fi]}" == "$_lb_target" ]]; then
        _list_cursor=$_lb_fi
        break
      fi
    done
    _list_follow_id=""
  fi
}
