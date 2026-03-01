# ── List mode snapshot (flat ordered array from snapshot data) ─────────────────
# Builds _list_items[] for the list view. Relies on zsh dynamic scoping to
# access snapshot arrays and list state declared in cmd__dash_loop.

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

    # Append in priority order
    local _lb_id
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
    for _lb_cron_col in 1 2 0; do
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
