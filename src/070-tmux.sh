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

# Check if Claude is still running in a task's tmux window (vs dead zsh fallback)
_tmux_claude_alive() {
  local name="$1"
  tmux_window_exists "$name" || return 1
  # Fast path: check pane_current_command directly
  local pane_cmd
  pane_cmd=$(tmux_cmd list-panes -t "board:${name}" -F '#{pane_current_command}' 2>/dev/null | head -1)
  [[ "$pane_cmd" == *claude* || "$pane_cmd" == *node* ]] && return 0
  # Fallback: pane_current_command reports "zsh" when launched via zsh -c wrapper;
  # check child processes of the pane's PID for claude or node
  local pane_pid
  pane_pid=$(tmux_cmd list-panes -t "board:${name}" -F '#{pane_pid}' 2>/dev/null | head -1)
  [[ -n "$pane_pid" ]] || return 1
  pgrep -P "$pane_pid" 2>/dev/null | xargs -I{} ps -o comm= -p {} 2>/dev/null | grep -qE 'claude|node'
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
}

pin_dashboard_to_zero() {
  local dash_idx
  dash_idx=$(tmux_cmd list-windows -t "board" -F '#{window_name} #{window_index}' 2>/dev/null \
    | awk '$1 == "dashboard" { print $2 }')
  if [[ -n "$dash_idx" && "$dash_idx" != "0" ]]; then
    tmux_cmd swap-window -s "board:dashboard" -t "board:0" 2>/dev/null || true
  fi
}

