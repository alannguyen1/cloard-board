# ── tmux helpers ───────────────────────────────────────────────────────────────
tmux_cmd() { tmux -L "$TMUX_SOCKET" "$@"; }

tmux_session_exists() {
  tmux_cmd has-session -t "board" 2>/dev/null
}

ensure_tmux_session() {
  if ! tmux_session_exists; then
    tmux_cmd new-session -d -s "board" -n "dashboard" -x 200 -y 50
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
S=cloard-board
tmux -L \$S select-window -t board:dashboard 2>/dev/null && exit 0
tmux -L \$S new-window -t board -n dashboard
tmux -L \$S respawn-window -k -t board:dashboard "exec '${SCRIPT_PATH}' _dash_loop"
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

_tmux_pane_pid() {
  local target="$1"
  tmux_cmd list-panes -t "$target" -F '#{pane_pid}' 2>/dev/null | head -1
}

_tmux_pane_command_line() {
  local target="$1"
  local pane_pid
  pane_pid=$(_tmux_pane_pid "$target")
  [[ -n "$pane_pid" ]] || return 1
  ps eww -o command= -p "$pane_pid" 2>/dev/null | head -1
}

_tmux_pane_claude_alive() {
  local target="$1"
  # Fast path: check pane_current_command directly
  local pane_cmd
  pane_cmd=$(tmux_cmd list-panes -t "$target" -F '#{pane_current_command}' 2>/dev/null | head -1)
  [[ "$pane_cmd" == *claude* || "$pane_cmd" == *node* ]] && return 0
  # Fallback: pane_current_command reports "zsh" when launched via zsh -c wrapper;
  # check child processes of the pane's PID for claude or node
  local pane_pid
  pane_pid=$(_tmux_pane_pid "$target")
  [[ -n "$pane_pid" ]] || return 1
  pgrep -P "$pane_pid" 2>/dev/null | xargs -I{} ps -o comm= -p {} 2>/dev/null | grep -qE 'claude|node'
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

_tmux_dashboard_task_id() {
  tmux_cmd display-message -t "board:dashboard.1" -p '' >/dev/null 2>&1 || return 1
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
  local dash_task
  dash_task=$(_tmux_dashboard_task_id 2>/dev/null || true)
  if [[ "$dash_task" == "$id" ]]; then
    tmux_cmd kill-pane -t "board:dashboard.1" 2>/dev/null || true
    closed=0
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
  while read -r wname; do
    [[ -z "$wname" || "$wname" == "dashboard" ]] && continue
    if _tmux_claude_alive "$wname"; then
      count=$((count + 1))
    fi
  done < <(tmux_cmd list-windows -t "board" -F '#{window_name}' 2>/dev/null)

  if tmux_cmd display-message -t "board:dashboard.1" -p '' >/dev/null 2>&1 \
    && _tmux_pane_claude_alive "board:dashboard.1"; then
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
