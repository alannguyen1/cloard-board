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

pin_dashboard_to_zero() {
  local dash_idx
  dash_idx=$(tmux_cmd list-windows -t "board" -F '#{window_name} #{window_index}' 2>/dev/null \
    | awk '$1 == "dashboard" { print $2 }')
  if [[ -n "$dash_idx" && "$dash_idx" != "0" ]]; then
    tmux_cmd swap-window -s "board:dashboard" -t "board:0" 2>/dev/null || true
  fi
}

