# ── tmux helpers ───────────────────────────────────────────────────────────────
tmux_cmd() { tmux -L "$TMUX_SOCKET" "$@"; }

tmux_session_exists() {
  tmux_cmd has-session -t "board" 2>/dev/null
}

ensure_tmux_session() {
  if ! tmux_session_exists; then
    local safe_script=${(q)SCRIPT_PATH}
    tmux_cmd new-session -d -s "board" -n "dashboard" -x 200 -y 50 "exec zsh ${safe_script} _dash_loop"
    pin_dashboard_to_zero
  fi
  # Active pane gets a bright blue border; inactive pane gets dark gray.
  # Heavy border lines for better visibility (tmux 3.2+, silently ignored on older).
  tmux_cmd set-option -t "board" pane-active-border-style "fg=#4488ff"
  tmux_cmd set-option -t "board" pane-border-style "fg=#333333"
  tmux_cmd set-option -t "board" pane-border-lines heavy 2>/dev/null || true
  # Always refresh the prefix-b binding (handles upgrades from old static binding).
  # Write a small helper script so run-shell doesn't need full cloard-board init.
  local _helper="${GLOBAL_DIR}/dash-switch.sh"
  cat > "$_helper" <<DASHEOF
#!/bin/sh
S='${TMUX_SOCKET}'
tmux -L \$S select-window -t board:dashboard 2>/dev/null && exit 0
tmux -L \$S new-window -t board -n dashboard
tmux -L \$S respawn-window -k -t board:dashboard "exec zsh '${SCRIPT_PATH}' _dash_loop"
tmux -L \$S select-window -t board:dashboard 2>/dev/null
DASHEOF
  chmod +x "$_helper"
  tmux_cmd bind-key -T prefix b run-shell "$_helper"
}

tmux_window_exists() {
  local name="$1"
  tmux_cmd list-windows -t "board" -F '#{window_name}' 2>/dev/null | grep -qx "$name"
}

tmux_create_window() {
  local name="$1"
  shift
  tmux_cmd new-window -t "board" -n "$name" "$@"
  pin_dashboard_to_zero
}

tmux_kill_window() {
  local name="$1"
  if tmux_window_exists "$name"; then
    tmux_cmd kill-window -t "board:$name" 2>/dev/null || true
  fi
}

tmux_select_window() {
  local name="$1"
  tmux_cmd select-window -t "board:$name" 2>/dev/null
}

_tmux_dashboard_start_loop() {
  local safe_script=${(q)SCRIPT_PATH}
  tmux_cmd respawn-window -k -t "board:dashboard" "exec zsh ${safe_script} _dash_loop"
  pin_dashboard_to_zero
}

_tmux_pane_pid() {
  local target="$1"
  tmux_cmd display-message -p -t "$target" '#{pane_pid}' 2>/dev/null
}

_tmux_pane_command_line() {
  local target="$1"
  local pane_pid
  pane_pid=$(_tmux_pane_pid "$target")
  [[ -n "$pane_pid" ]] || return 1
  ps eww -o command= -p "$pane_pid" 2>/dev/null | head -1
}

_tmux_pane_size() {
  local target="$1"
  local pane_size pane_w pane_h
  pane_size=$(tmux_cmd display-message -p -t "$target" '#{pane_width} #{pane_height}' 2>/dev/null || true)
  read -r pane_w pane_h <<< "$pane_size"
  [[ "$pane_w" == <-> && "$pane_h" == <-> ]] || return 1
  printf '%s %s\n' "$pane_w" "$pane_h"
}

_tmux_dashboard_primary_pane_size() {
  _tmux_pane_size "board:dashboard.0"
}

_tmux_dashboard_rehome_extra_panes() {
  tmux_session_exists || return 1
  tmux_window_exists "dashboard" || return 1

  local dock_data dock_kind="" dock_id="" keep_idx="" moved=1
  dock_data=$(_tmux_dashboard_read_dock 2>/dev/null || true)
  if [[ -n "$dock_data" ]]; then
    IFS=$'\x1e' read -r dock_kind dock_id <<< "$dock_data"
  fi

  local pane_idx pane_task
  while IFS= read -r pane_idx; do
    [[ "$pane_idx" == <-> ]] || continue
    (( pane_idx > 0 )) || continue
    pane_task=$(tmux_cmd display-message -p -t "board:dashboard.${pane_idx}" '#{@cloard_task_id}' 2>/dev/null || true)
    [[ "$pane_task" == "(null)" ]] && pane_task=""
    if [[ -n "$dock_id" && -z "$keep_idx" && "$pane_task" == "$dock_id" ]]; then
      keep_idx="$pane_idx"
      break
    fi
  done < <(tmux_cmd list-panes -t "board:dashboard" -F '#{pane_index}' 2>/dev/null)

  if [[ -n "$keep_idx" && "$keep_idx" != "1" ]]; then
    tmux_cmd swap-pane -d -s "board:dashboard.${keep_idx}" -t "board:dashboard.1" 2>/dev/null || true
    keep_idx="1"
    moved=0
  fi

  while IFS= read -r pane_idx; do
    [[ "$pane_idx" == <-> ]] || continue
    (( pane_idx > 0 )) || continue
    [[ -n "$keep_idx" && "$pane_idx" == "$keep_idx" ]] && continue

    local pane_name
    pane_task=$(tmux_cmd display-message -p -t "board:dashboard.${pane_idx}" '#{@cloard_task_id}' 2>/dev/null || true)
    [[ "$pane_task" == "(null)" ]] && pane_task=""
    if [[ -n "$pane_task" && "$pane_task" != "(null)" ]] && ! tmux_window_exists "$pane_task"; then
      pane_name="$pane_task"
    else
      pane_name="dashboard-extra-${pane_idx}-$(date +%s)"
    fi

    tmux_cmd break-pane -d -s "board:dashboard.${pane_idx}" -n "$pane_name" 2>/dev/null || continue
    moved=0
  done < <(tmux_cmd list-panes -t "board:dashboard" -F '#{pane_index}' 2>/dev/null)

  return "$moved"
}

_tmux_process_matches_runtime() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1

  local comm
  comm=$(ps -o comm= -p "$pid" 2>/dev/null | head -1)
  case "${comm##*/}" in
    claude|node|bun) return 0 ;;
  esac

  local cmdline
  cmdline=$(ps eww -o command= -p "$pid" 2>/dev/null | head -1)
  [[ -n "$cmdline" ]] || return 1
  echo "$cmdline" | grep -qiE '(^|[[:space:]/])(claude|node|bun)([[:space:]]|$)'
}

_tmux_process_tree_runtime_alive() {
  local root_pid="$1"
  [[ -n "$root_pid" ]] || return 1

  local frontier="${root_pid}"
  local -A seen=()

  while [[ -n "$frontier" ]]; do
    local next_frontier=""
    local pid
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      [[ -n "${seen[$pid]:-}" ]] && continue
      seen[$pid]=1

      _tmux_process_matches_runtime "$pid" && return 0

      local children
      children=$(pgrep -P "$pid" 2>/dev/null || true)
      if [[ -n "$children" ]]; then
        next_frontier+="${children}"$'\n'
      fi
    done <<< "$frontier"
    frontier="$next_frontier"
  done

  return 1
}

_tmux_pane_claude_alive() {
  local target="$1"
  # Fast path: check pane_current_command directly
  local pane_cmd
  pane_cmd=$(tmux_cmd display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || true)
  [[ "$pane_cmd" == *claude* || "$pane_cmd" == *node* || "$pane_cmd" == *bun* ]] && return 0
  # Fallback: pane_current_command reports "zsh" for wrapped launches. Inspect
  # the full descendant process tree so nested wrappers still count as live.
  local pane_pid
  pane_pid=$(_tmux_pane_pid "$target")
  [[ -n "$pane_pid" ]] || return 1
  _tmux_process_tree_runtime_alive "$pane_pid"
}

_tmux_pane_task_id() {
  local target="$1"
  local pane_cmdline
  pane_cmdline=$(_tmux_pane_command_line "$target") || return 1
  echo "$pane_cmdline" | sed -n 's/.*CLOARD_TASK_ID=\([^ ;]*\).*/\1/p' | head -1
}

_tmux_mark_task_pane() {
  local target="$1" task_id="$2"
  tmux_cmd set-option -pt "$target" @cloard_task_id "$task_id" 2>/dev/null || true
}

_tmux_dashboard_window_option() {
  local option="$1"
  tmux_window_exists "dashboard" || return 1
  tmux_cmd display-message -p -t "board:dashboard" "#{@${option}}" 2>/dev/null
}

_tmux_dashboard_session_option() {
  local option="$1"
  tmux_session_exists || return 1
  tmux_cmd show-options -v -t "board" "$option" 2>/dev/null
}

_tmux_dashboard_window_active() {
  tmux_window_exists "dashboard" || return 1
  [[ "$(tmux_cmd display-message -p -t "board:dashboard" '#{window_active}' 2>/dev/null || true)" == "1" ]]
}

_tmux_dashboard_sync_dock_to_window() {
  tmux_window_exists "dashboard" || return 0
  local persist kind dock_id
  persist=$(_tmux_dashboard_session_option "@cloard_dash_dock_persist" 2>/dev/null || true)
  kind=$(_tmux_dashboard_session_option "@cloard_dash_dock_kind" 2>/dev/null || true)
  dock_id=$(_tmux_dashboard_session_option "@cloard_dash_dock_id" 2>/dev/null || true)
  if [[ "$persist" == "1" && ( "$kind" == "task" || "$kind" == "cron" ) && -n "$dock_id" ]]; then
    tmux_cmd set-option -w -t "board:dashboard" @cloard_dock_persist "1" 2>/dev/null || true
    tmux_cmd set-option -w -t "board:dashboard" @cloard_dock_kind "$kind" 2>/dev/null || true
    tmux_cmd set-option -w -t "board:dashboard" @cloard_dock_id "$dock_id" 2>/dev/null || true
  fi
}

_tmux_dashboard_set_dock() {
  local kind="$1" dock_id="$2"
  [[ "$kind" == "task" || "$kind" == "cron" ]] || return 1
  [[ -n "$dock_id" ]] || return 1
  tmux_session_exists || return 1
  tmux_cmd set-option -t "board" @cloard_dash_dock_persist "1" 2>/dev/null || true
  tmux_cmd set-option -t "board" @cloard_dash_dock_kind "$kind" 2>/dev/null || true
  tmux_cmd set-option -t "board" @cloard_dash_dock_id "$dock_id" 2>/dev/null || true
  if tmux_window_exists "dashboard"; then
    tmux_cmd set-option -w -t "board:dashboard" @cloard_dock_persist "1" 2>/dev/null || true
    tmux_cmd set-option -w -t "board:dashboard" @cloard_dock_kind "$kind" 2>/dev/null || true
    tmux_cmd set-option -w -t "board:dashboard" @cloard_dock_id "$dock_id" 2>/dev/null || true
  fi
}

_tmux_dashboard_clear_dock() {
  tmux_session_exists || return 0
  tmux_cmd set-option -u -t "board" @cloard_dash_dock_persist 2>/dev/null || true
  tmux_cmd set-option -u -t "board" @cloard_dash_dock_kind 2>/dev/null || true
  tmux_cmd set-option -u -t "board" @cloard_dash_dock_id 2>/dev/null || true
  if tmux_window_exists "dashboard"; then
    tmux_cmd set-option -w -u -t "board:dashboard" @cloard_dock_persist 2>/dev/null || true
    tmux_cmd set-option -w -u -t "board:dashboard" @cloard_dock_kind 2>/dev/null || true
    tmux_cmd set-option -w -u -t "board:dashboard" @cloard_dock_id 2>/dev/null || true
  fi
}

_tmux_dashboard_read_dock() {
  tmux_session_exists || return 1

  local persist="" kind="" dock_id=""
  if tmux_window_exists "dashboard"; then
    persist=$(_tmux_dashboard_window_option "cloard_dock_persist" 2>/dev/null || true)
    kind=$(_tmux_dashboard_window_option "cloard_dock_kind" 2>/dev/null || true)
    dock_id=$(_tmux_dashboard_window_option "cloard_dock_id" 2>/dev/null || true)
  fi

  if [[ "$persist" != "1" ]]; then
    persist=$(_tmux_dashboard_session_option "@cloard_dash_dock_persist" 2>/dev/null || true)
    kind=$(_tmux_dashboard_session_option "@cloard_dash_dock_kind" 2>/dev/null || true)
    dock_id=$(_tmux_dashboard_session_option "@cloard_dash_dock_id" 2>/dev/null || true)
    if [[ "$persist" == "1" ]]; then
      _tmux_dashboard_sync_dock_to_window
    fi
  fi

  if [[ "$persist" != "1" ]]; then
    return 1
  fi

  if [[ "$kind" != "task" && "$kind" != "cron" ]]; then
    _tmux_dashboard_clear_dock
    return 1
  fi

  if [[ -z "$dock_id" || "$dock_id" == "(null)" ]]; then
    _tmux_dashboard_clear_dock
    return 1
  fi

  printf '%s\x1e%s\n' "$kind" "$dock_id"
}

_tmux_dashboard_has_dock() {
  _tmux_dashboard_read_dock >/dev/null 2>&1
}

_tmux_dashboard_dock_matches() {
  local want_kind="$1" want_id="$2"
  local dock_data
  dock_data=$(_tmux_dashboard_read_dock 2>/dev/null) || return 1
  local dock_kind dock_id
  IFS=$'\x1e' read -r dock_kind dock_id <<< "$dock_data"
  [[ "$dock_kind" == "$want_kind" && "$dock_id" == "$want_id" ]]
}

_tmux_dashboard_dock_task_id() {
  local dock_data
  dock_data=$(_tmux_dashboard_read_dock 2>/dev/null) || return 1

  local dock_kind dock_id
  IFS=$'\x1e' read -r dock_kind dock_id <<< "$dock_data"
  [[ "$dock_kind" == "task" && -n "$dock_id" ]] || return 1
  echo "$dock_id"
}

_tmux_dashboard_pane_count() {
  tmux_session_exists || return 1
  tmux_window_exists "dashboard" || return 1

  local pane_count
  pane_count=$(tmux_cmd display-message -p -t "board:dashboard" '#{window_panes}' 2>/dev/null || true)
  [[ "$pane_count" == <-> ]] || return 1
  echo "$pane_count"
}

_tmux_dashboard_has_split() {
  local pane_count
  pane_count=$(_tmux_dashboard_pane_count 2>/dev/null) || return 1
  (( pane_count > 1 ))
}

_tmux_dashboard_active_pane_index() {
  tmux_session_exists || return 1
  tmux_window_exists "dashboard" || return 1

  local pane_idx
  pane_idx=$(tmux_cmd list-panes -t "board:dashboard" -F '#{pane_index} #{pane_active}' 2>/dev/null \
    | awk '$2 == "1" { print $1; exit }')
  [[ "$pane_idx" == <-> ]] || return 1
  echo "$pane_idx"
}

_tmux_dashboard_task_id() {
  _tmux_dashboard_has_split || return 1
  local task_id
  task_id=$(tmux_cmd display-message -p -t "board:dashboard.1" '#{@cloard_task_id}' 2>/dev/null || true)
  if [[ -n "$task_id" && "$task_id" != "(null)" ]]; then
    echo "$task_id"
    return 0
  fi
  task_id=$(_tmux_pane_task_id "board:dashboard.1" 2>/dev/null) || return 1
  [[ -n "$task_id" ]] || return 1
  echo "$task_id"
}

# Check if Claude is still running in a task's tmux window (vs dead zsh fallback)
_tmux_claude_alive() {
  local name="$1"
  tmux_window_exists "$name" || return 1
  _tmux_pane_claude_alive "board:${name}"
}

_tmux_runtime_window_names() {
  tmux_session_exists || return 1
  tmux_cmd list-windows -t "board" -F '#{window_name}' 2>/dev/null | grep -vx 'dashboard'
}

_tmux_live_runtime_window_names() {
  tmux_session_exists || return 1

  local wname
  while IFS= read -r wname; do
    [[ -n "$wname" ]] || continue
    _tmux_claude_alive "$wname" && echo "$wname"
  done < <(_tmux_runtime_window_names 2>/dev/null || true)
}

_tmux_task_runtime_exists() {
  local id="$1"
  tmux_session_exists || return 1
  tmux_window_exists "$id" && return 0
  local dash_task
  dash_task=$(_tmux_dashboard_task_id 2>/dev/null || true)
  [[ "$dash_task" == "$id" ]]
}

_tmux_task_runtime_live() {
  local id="$1"
  tmux_session_exists || return 1
  if tmux_window_exists "$id" && _tmux_claude_alive "$id"; then
    return 0
  fi
  local dash_task
  dash_task=$(_tmux_dashboard_task_id 2>/dev/null || true)
  [[ "$dash_task" == "$id" ]] || return 1
  _tmux_pane_claude_alive "board:dashboard.1"
}

_tmux_close_task_runtime() {
  local id="$1"
  tmux_session_exists || return 1
  local closed=1
  if _tmux_dashboard_dock_matches "task" "$id"; then
    _tmux_dashboard_clear_dock
  fi
  if _tmux_dashboard_has_split; then
    local dash_task
    dash_task=$(_tmux_dashboard_task_id 2>/dev/null || true)
    if [[ "$dash_task" == "$id" ]]; then
      tmux_cmd kill-pane -t "board:dashboard.1" 2>/dev/null || true
      closed=0
    fi
  fi
  if tmux_window_exists "$id"; then
    tmux_kill_window "$id"
    closed=0
  fi
  return "$closed"
}

_tmux_focus_task_runtime() {
  local id="$1"
  if tmux_window_exists "$id"; then
    tmux_select_window "$id"
    return 0
  fi
  _tmux_dashboard_has_split || return 1
  local dash_task
  dash_task=$(_tmux_dashboard_task_id 2>/dev/null || true)
  if [[ "$dash_task" == "$id" ]]; then
    tmux_cmd select-window -t "board:dashboard" 2>/dev/null || true
    tmux_cmd select-pane -t "board:dashboard.1" 2>/dev/null || true
    return 0
  fi
  return 1
}

_tmux_live_session_count() {
  local count=0
  tmux_session_exists || { echo "0"; return 0; }

  local wname
  while IFS= read -r wname; do
    [[ -n "$wname" ]] && count=$((count + 1))
  done < <(_tmux_live_runtime_window_names 2>/dev/null || true)

  if _tmux_dashboard_has_split && _tmux_pane_claude_alive "board:dashboard.1"; then
    count=$((count + 1))
  fi

  echo "$count"
}

# Launch a Claude session in a new tmux window with standard env vars.
# Usage: _tmux_launch_claude <task_id> <work_dir> <claude_cmd>
_tmux_launch_claude() {
  local id="$1" work_dir="$2" claude_cmd="$3"
  local safe_global_dir=${(q)GLOBAL_DIR}
  local safe_repo_path=${(q)work_dir}
  local safe_work_dir=${(q)work_dir}
  tmux_create_window "$id" "zsh" "-c" \
    "export CLOARD_TASK_ID=${id} CLOARD_BOARD_DIR=${safe_global_dir} CLOARD_REPO_PATH=${safe_repo_path} && cd ${safe_work_dir} && ${claude_cmd}; zsh; tmux -L cloard-board select-window -t board:dashboard 2>/dev/null"
  _tmux_mark_task_pane "board:${id}.0" "$id"
}

pin_dashboard_to_zero() {
  local dash_idx
  dash_idx=$(tmux_cmd list-windows -t "board" -F '#{window_name} #{window_index}' 2>/dev/null \
    | awk '$1 == "dashboard" { print $2 }')
  if [[ -n "$dash_idx" && "$dash_idx" != "0" ]]; then
    tmux_cmd swap-window -s "board:dashboard" -t "board:0" 2>/dev/null || true
  fi
}
