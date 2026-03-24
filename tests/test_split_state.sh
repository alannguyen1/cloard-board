#!/usr/bin/env zsh
# Functional regressions for stale dashboard split state.
set -euo pipefail
setopt KSH_ARRAYS

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOARD="$SCRIPT_DIR/../cloard-board"
TMPDIR_TEST=$(mktemp -d)

pass=0
fail=0
total=0

cleanup() {
  tmux -L "${TMUX_SOCKET:-cloard-board}" kill-server 2>/dev/null || true
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  total=$((total + 1))
  if [[ "$expected" == "$actual" ]]; then
    echo "  ✓ $label"
    pass=$((pass + 1))
  else
    echo "  ✗ $label"
    echo "    expected: $(printf '%q' "$expected")"
    echo "    actual:   $(printf '%q' "$actual")"
    fail=$((fail + 1))
  fi
}

dashboard_panes() {
  tmux_cmd list-panes -t "board:dashboard" 2>/dev/null | wc -l | tr -d ' '
}

dock_state() {
  _tmux_dashboard_read_dock 2>/dev/null || true
}

writer_lines() {
  local logfile="$1"
  [[ -f "$logfile" ]] || { echo "0"; return 0; }
  wc -l < "$logfile" | tr -d ' '
}

reset_tmux() {
  tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
  ensure_tmux_session
}

seed_single_task_state() {
  local task_id="$1" repo_dir="$2" task_status="${3:-active}"
  cat > "$GLOBAL_STATE" <<JSON
{"version":5,"next_task_id":2,"repos":[{"name":"repo","path":"$repo_dir","type":"git","archived":false}],"tasks":[{"id":"$task_id","title":"persistent dock","repo":"repo","status":"$task_status","created_at":"2026-03-21T00:00:00Z","started_at":"2026-03-21T00:00:00Z","status_changed_at":"2026-03-21T00:00:00Z","completed_at":null,"claude_status":"working","worktree_mode":"none","branch":null,"session_uid":"uid-$task_id","session_history":["uid-$task_id"]}],"cron_jobs":[],"cron_runs":[]}
JSON
}

open_writer_split() {
  local task_id="$1" logfile="$2"
  local safe_log=${(q)logfile}
  local safe_writer=${(q)WRITER_JS}
  tmux_cmd new-window -t "board" -n "$task_id" \
    "zsh -c 'export CLOARD_TASK_ID=${task_id} WRITER_LOG=${safe_log}; node ${safe_writer}'"
  _tmux_mark_task_pane "board:${task_id}.0" "$task_id"
  _snapshot_tasks
  _split_open "$task_id"
}

export TMUX_SOCKET="cloard-board-split-$$"
export GLOBAL_DIR="$TMPDIR_TEST/global"
export GLOBAL_STATE="$GLOBAL_DIR/state.json"
export HOOKS_DIR="$GLOBAL_DIR/hooks"
mkdir -p "$HOOKS_DIR"

MOCK_BIN="$TMPDIR_TEST/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/claude" <<'EOF'
#!/bin/sh
node -e "setInterval(function(){}, 1000000)"
EOF
chmod +x "$MOCK_BIN/claude"
export PATH="$MOCK_BIN:$PATH"

WRITER_JS="$TMPDIR_TEST/writer.js"
cat > "$WRITER_JS" <<'EOF'
const fs = require('fs');
const log = process.env.WRITER_LOG;
fs.writeFileSync(log, 'started\n');
let i = 0;
setInterval(() => {
  fs.appendFileSync(log, `tick-${++i}\n`);
}, 500);
EOF

BOARD_SRC="$TMPDIR_TEST/board_src.zsh"
sed \
  -e '/^main "\$@"$/d' \
  -e 's|^readonly TMUX_SOCKET=.*|readonly TMUX_SOCKET="${TMUX_SOCKET:-cloard-board}"|' \
  -e 's|^readonly GLOBAL_DIR=.*|readonly GLOBAL_DIR="${GLOBAL_DIR:-/tmp}"|' \
  -e 's|^readonly GLOBAL_STATE=.*|readonly GLOBAL_STATE="${GLOBAL_STATE:-$GLOBAL_DIR/state.json}"|' \
  -e 's|^readonly HOOKS_DIR=.*|readonly HOOKS_DIR="${HOOKS_DIR:-$GLOBAL_DIR/hooks}"|' \
  "$BOARD" > "$BOARD_SRC"

source "$BOARD_SRC"
SCRIPT_PATH="$BOARD"

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_paths _repo_types _repo_stale _repo_task_count _repo_cols _repo_col_cnt
typeset -A _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data _cron_col_ids _cron_col_cnt
typeset -A _list_group_collapsed
typeset -a _repo_names _list_items
typeset _total_task_count=0 _active_count=0 _review_count=0
typeset _has_cron_data=false
typeset _view_mode="list"
typeset -i _split_active=0
typeset _split_task_id=""
typeset -i _split_is_cron=0
typeset -i _show_done=0
typeset -i _list_cursor=0
typeset -i _list_scroll_top=0
typeset _list_follow_id=""
typeset _list_follow_type="task"

echo "=== Split state regressions ==="

echo ""
echo "A. Real split detection ignores tmux's false-positive dashboard.1 target"
reset_tmux
tmux_cmd split-window -h -t "board:dashboard" "sleep 30"
assert_eq "dashboard starts with two panes" "2" "$(dashboard_panes)"
assert_eq "helper detects real split" "yes" "$(_tmux_dashboard_has_split && echo yes || echo no)"
assert_eq "dashboard.1 target resolves while split exists" "ok" "$(tmux_cmd display-message -t "board:dashboard.1" -p ok 2>/dev/null || echo fail)"
tmux_cmd kill-pane -t "board:dashboard.1"
assert_eq "dashboard collapses to one pane after kill" "1" "$(dashboard_panes)"
assert_eq "dashboard.1 still resolves after collapse" "ok" "$(tmux_cmd display-message -t "board:dashboard.1" -p ok 2>/dev/null || echo fail)"
assert_eq "helper reports no split after collapse" "no" "$(_tmux_dashboard_has_split && echo yes || echo no)"

echo ""
echo "B. Reopening a done task from list mode self-heals stale split state"
reset_tmux
REPO_DIR="$TMPDIR_TEST/repo"
mkdir -p "$REPO_DIR"
cat > "$GLOBAL_STATE" <<JSON
{"version":5,"next_task_id":2,"repos":[{"name":"repo","path":"$REPO_DIR","type":"git","archived":false}],"tasks":[{"id":"t-001","title":"stale split reopen","repo":"repo","status":"active","created_at":"2026-03-21T00:00:00Z","started_at":"2026-03-21T00:00:00Z","status_changed_at":"2026-03-21T00:00:00Z","completed_at":null,"claude_status":"working","worktree_mode":"none","branch":null,"session_uid":"uid-001","session_history":["uid-001"]}],"cron_jobs":[],"cron_runs":[]}
JSON

_snapshot_tasks
_list_group_collapsed=()
_show_done=0
_split_active=0
_split_task_id=""
_split_is_cron=0

tmux_cmd new-window -t "board" -n "t-001" "zsh -c 'export CLOARD_TASK_ID=t-001; node -e \"setInterval(function(){}, 1000000)\"'"
_tmux_mark_task_pane "board:t-001.0" "t-001"

_split_open "t-001"
assert_eq "initial task opens in split" "2" "$(dashboard_panes)"
assert_eq "split state marked active" "1" "$_split_active"
assert_eq "split state tracks task" "t-001" "$_split_task_id"

cmd_done "t-001" >/dev/null 2>&1 || true
assert_eq "done collapses dashboard back to one pane" "1" "$(dashboard_panes)"
assert_eq "task state is done after x-path cleanup" "done" "$(task_status "t-001")"
assert_eq "local split flag is now stale" "1" "$_split_active"

_show_done=1
_snapshot_tasks
_list_build_items
_list_cursor=1
assert_eq "cursor points at done task in list" "task:t-001" "${_list_items[$_list_cursor]}"

_list_handle_key "ENTER"
assert_eq "reopen restores right-hand split" "2" "$(dashboard_panes)"
assert_eq "task reactivates after reopen" "active" "$(task_status "t-001")"
assert_eq "split state active after reopen" "1" "$_split_active"
assert_eq "split state follows reopened task" "t-001" "$_split_task_id"

echo ""
echo "C. Close/focus guards are safe when split state is stale"
reset_tmux
_split_active=1
_split_task_id="t-guard"
_split_is_cron=0
assert_eq "dashboard starts single-pane" "1" "$(dashboard_panes)"
_split_close
assert_eq "split_close keeps single-pane dashboard intact" "1" "$(dashboard_panes)"
assert_eq "split_close clears active flag" "0" "$_split_active"
assert_eq "split_close clears tracked task" "" "$_split_task_id"

focus_rc=0
_tmux_focus_task_runtime "t-guard" || focus_rc=$?
assert_eq "focus returns non-zero without a real split" "1" "$focus_rc"

close_rc=0
_tmux_close_task_runtime "t-guard" || close_rc=$?
assert_eq "close returns non-zero without a real runtime" "1" "$close_rc"
assert_eq "close does not kill the dashboard pane" "1" "$(dashboard_panes)"

echo ""
echo "D. Dashboard switching keeps a live docked session running"
reset_tmux
REPO_DIR="$TMPDIR_TEST/repo-live"
mkdir -p "$REPO_DIR"
seed_single_task_state "t-live" "$REPO_DIR"
_show_done=0
_list_group_collapsed=()
_split_active=0
_split_task_id=""
_split_is_cron=0
writer_log="$TMPDIR_TEST/t-live.log"
open_writer_split "t-live" "$writer_log"
sleep 2
before_lines=$(writer_lines "$writer_log")
cmd__dash_switch
sleep 2
after_lines=$(writer_lines "$writer_log")
assert_eq "cmd__dash_switch keeps dashboard split intact" "2" "$(dashboard_panes)"
assert_eq "dock metadata preserved across dashboard switch" $'task\x1et-live' "$(dock_state)"
assert_eq "writer keeps streaming after dashboard switch" "yes" "$( [[ "$after_lines" -gt "$before_lines" ]] && echo yes || echo no )"

echo ""
echo "E. Persisted dock restores after fullscreen-style temporary hide"
reset_tmux
REPO_DIR="$TMPDIR_TEST/repo-restore"
mkdir -p "$REPO_DIR"
seed_single_task_state "t-restore" "$REPO_DIR"
_show_done=0
_list_group_collapsed=()
_split_active=0
_split_task_id=""
_split_is_cron=0
writer_log="$TMPDIR_TEST/t-restore.log"
open_writer_split "t-restore" "$writer_log"
sleep 2
before_lines=$(writer_lines "$writer_log")
_split_close keep
assert_eq "temporary hide collapses dashboard to one pane" "1" "$(dashboard_panes)"
assert_eq "temporary hide keeps dock metadata" $'task\x1et-restore' "$(dock_state)"
_split_restore_persisted_if_needed
sleep 2
after_lines=$(writer_lines "$writer_log")
assert_eq "restore reopens the right-hand split" "2" "$(dashboard_panes)"
assert_eq "restore keeps the same dock target" "t-restore" "$_split_task_id"
assert_eq "restore keeps session output advancing" "yes" "$( [[ "$after_lines" -gt "$before_lines" ]] && echo yes || echo no )"

echo ""
echo "F. Dashboard restore gate restores a pinned dock while the dashboard stays active"
reset_tmux
REPO_DIR="$TMPDIR_TEST/repo-loop-restore"
mkdir -p "$REPO_DIR"
seed_single_task_state "t-loop" "$REPO_DIR"
_show_done=0
_list_group_collapsed=()
_split_active=0
_split_task_id=""
_split_is_cron=0
open_writer_split "t-loop" "$TMPDIR_TEST/t-loop.log"
sleep 2
assert_eq "loop restore precondition is split dashboard" "2" "$(dashboard_panes)"
tmux_cmd kill-pane -t "board:dashboard.1"
assert_eq "pane loss collapses dashboard immediately" "1" "$(dashboard_panes)"
assert_eq "pane loss keeps dock metadata" $'task\x1et-loop' "$(dock_state)"
assert_eq "dashboard stays selected before restore" "1" "$(tmux_cmd display-message -p -t "board:dashboard" '#{window_active}' 2>/dev/null || echo 0)"
restore_rc=0
_dash_restore_dock_if_needed "$(dock_state)" || restore_rc=$?
assert_eq "dashboard restore helper succeeds" "0" "$restore_rc"
sleep 1
assert_eq "dashboard restore helper reopens right-hand split" "2" "$(dashboard_panes)"
assert_eq "restored pane is tagged with the same task" "t-loop" "$(tmux_cmd display-message -p -t "board:dashboard.1" '#{@cloard_task_id}' 2>/dev/null || true)"

echo ""
echo "G. Persisted dock survives dashboard recreation"
reset_tmux
REPO_DIR="$TMPDIR_TEST/repo-recreate"
mkdir -p "$REPO_DIR"
seed_single_task_state "t-recreate" "$REPO_DIR"
_show_done=0
_list_group_collapsed=()
_split_active=0
_split_task_id=""
_split_is_cron=0
writer_log="$TMPDIR_TEST/t-recreate.log"
open_writer_split "t-recreate" "$writer_log"
sleep 2
before_lines=$(writer_lines "$writer_log")
_split_close keep
tmux_kill_window "dashboard"
assert_eq "dashboard window removed" "no" "$(tmux_window_exists "dashboard" && echo yes || echo no)"
assert_eq "session mirror keeps dock metadata after dashboard close" $'task\x1et-recreate' "$(dock_state)"
tmux_cmd new-window -t "board" -n "dashboard" "zsh -c 'sleep 1000'"
_split_restore_persisted_if_needed
sleep 2
after_lines=$(writer_lines "$writer_log")
assert_eq "restored dashboard has two panes after recreation" "2" "$(dashboard_panes)"
assert_eq "recreated dashboard keeps dock metadata" $'task\x1et-recreate' "$(dock_state)"
assert_eq "writer keeps streaming after dashboard recreation" "yes" "$( [[ "$after_lines" -gt "$before_lines" ]] && echo yes || echo no )"

echo ""
echo "H. Explicit undock keys clear persisted dock metadata"
reset_tmux
REPO_DIR="$TMPDIR_TEST/repo-undock"
mkdir -p "$REPO_DIR"
seed_single_task_state "t-undock" "$REPO_DIR"
_show_done=0
_list_group_collapsed=()
_split_active=0
_split_task_id=""
_split_is_cron=0
_list_cursor=1
open_writer_split "t-undock" "$TMPDIR_TEST/t-undock.log"
_list_handle_key "b"
assert_eq "b undocks back to one pane" "1" "$(dashboard_panes)"
assert_eq "b clears persisted dock metadata" "" "$(dock_state)"
_split_open "t-undock"
_list_handle_key "ESC"
assert_eq "Esc undocks back to one pane" "1" "$(dashboard_panes)"
assert_eq "Esc clears persisted dock metadata" "" "$(dock_state)"

echo ""
echo "I. View toggle is pinned to list while a dock is persisted"
reset_tmux
_view_mode="kanban"
_tmux_dashboard_set_dock "task" "t-dock"
_dash_toggle_view_mode
assert_eq "dock guard forces list view" "list" "$_view_mode"
_tmux_dashboard_clear_dock
_view_mode="list"
_dash_toggle_view_mode
assert_eq "view toggle works normally after dock clears" "kanban" "$_view_mode"

echo ""
echo "J. Invalid persisted dock targets clear safely"
reset_tmux
_show_done=0
_list_group_collapsed=()
_split_active=0
_split_task_id=""
_split_is_cron=0
_tmux_dashboard_set_dock "task" "t-missing"
restore_rc=0
_split_restore_persisted_if_needed || restore_rc=$?
assert_eq "invalid restore returns non-zero" "1" "$restore_rc"
assert_eq "invalid restore leaves dashboard single-pane" "1" "$(dashboard_panes)"
assert_eq "invalid restore clears dock metadata" "" "$(dock_state)"

echo ""
echo "K. Idle external-state polling stays clean without changes"
_dash_mark_snapshot_dirty() { _snapshot_dirty=1; _list_needs_rebuild=1; _full_redraw=1; }
_dash_mark_list_dirty() { _list_needs_rebuild=1; _full_redraw=1; }
_dash_mark_dock_dirty() { _dock_dirty=1; _full_redraw=1; }
_dash_mark_layout_dirty() { _layout_dirty=1; _full_redraw=1; }
_state_file_mtime() { echo "100"; }
_tmux_dashboard_pane_count() { echo "1"; }
_tmux_dashboard_active_pane_index() { echo "0"; }
_tmux_dashboard_window_active() { return 0; }
_tmux_dashboard_has_dock() { return 1; }
typeset -i _snapshot_dirty=0 _dock_dirty=0 _layout_dirty=0 _full_redraw=0 _list_needs_rebuild=0
typeset _state_mtime="100"
typeset _dock_data=""
typeset -i _dash_last_pane_count=1 _dash_last_window_active=1
typeset _dash_last_active_pane="0"
_dash_poll_external_state
assert_eq "idle poll keeps snapshot clean" "0" "$_snapshot_dirty"
assert_eq "idle poll keeps dock clean" "0" "$_dock_dirty"
assert_eq "idle poll keeps layout clean" "0" "$_layout_dirty"
assert_eq "idle poll keeps list clean" "0" "$_list_needs_rebuild"
assert_eq "idle poll keeps redraw clean" "0" "$_full_redraw"

echo ""
echo "L. Returning focus to pane 0 triggers redraw only"
_state_file_mtime() { echo "100"; }
_tmux_dashboard_pane_count() { echo "2"; }
_tmux_dashboard_active_pane_index() { echo "0"; }
_tmux_dashboard_window_active() { return 0; }
_tmux_dashboard_has_dock() { return 1; }
typeset -i _snapshot_dirty=0 _dock_dirty=0 _layout_dirty=0 _full_redraw=0 _list_needs_rebuild=0
typeset _state_mtime="100"
typeset _dock_data=$'task\x1et-focus'
typeset -i _dash_last_pane_count=2 _dash_last_window_active=1
typeset _dash_last_active_pane="1"
_dash_poll_external_state
assert_eq "pane 0 focus triggers redraw" "1" "$_full_redraw"
assert_eq "pane 0 focus keeps snapshot clean" "0" "$_snapshot_dirty"
assert_eq "pane 0 focus keeps dock clean" "0" "$_dock_dirty"
assert_eq "pane 0 focus keeps layout clean" "0" "$_layout_dirty"
assert_eq "pane 0 focus keeps list clean" "0" "$_list_needs_rebuild"

echo ""
echo "M. Dashboard layout uses tmux pane geometry"
assert_eq "primary pane size helper present" "1" "$(grep -c '^_tmux_dashboard_primary_pane_size()' "$BOARD" | tr -d ' ')"
assert_eq "dash loop reads tmux pane size first" "1" "$(grep -c '_tmux_dashboard_primary_pane_size 2>/dev/null || true' "$BOARD" | tr -d ' ')"
tmux_cmd() {
  if [[ "$1" == "display-message" ]]; then
    echo "45 40"
    return 0
  fi
  return 1
}
assert_eq "pane size helper parses tmux width/height output" "45 40" "$(_tmux_pane_size "board:dashboard.0")"

echo ""
echo "N. Dashboard poll self-heals malformed 3-pane layouts"
_state_file_mtime() { echo "100"; }
typeset -i _rehome_calls=0
_tmux_dashboard_pane_count() {
  if [[ $_rehome_calls -gt 0 ]]; then
    echo "2"
  else
    echo "3"
  fi
}
_tmux_dashboard_rehome_extra_panes() { _rehome_calls=$((_rehome_calls + 1)); return 0; }
_tmux_dashboard_active_pane_index() { echo "0"; }
_tmux_dashboard_window_active() { return 0; }
_tmux_dashboard_has_dock() { return 1; }
typeset -i _snapshot_dirty=0 _dock_dirty=0 _layout_dirty=0 _full_redraw=0 _list_needs_rebuild=0
typeset _state_mtime="100"
typeset _dock_data=$'task\x1et-focus'
typeset -i _dash_last_pane_count=2 _dash_last_window_active=1
typeset _dash_last_active_pane="0"
_dash_poll_external_state
assert_eq "3-pane dashboard triggers rehome helper" "1" "$_rehome_calls"
assert_eq "rehome marks dock dirty" "1" "$_dock_dirty"
assert_eq "rehome marks layout dirty" "1" "$_layout_dirty"
assert_eq "rehome marks list dirty" "1" "$_list_needs_rebuild"

echo ""
echo "O. Dashboard render resets viewport state before frame output"
assert_eq "tui_reset_viewport helper present" "1" "$(grep -c '^tui_reset_viewport()' "$BOARD" | tr -d ' ')"
assert_eq "dash loop resets viewport on alt-screen enter" "1" "$(grep -c '^[[:space:]]*tui_reset_viewport$' "$BOARD" | tr -d ' ')"
assert_eq "frame output resets scroll region/origin mode" "1" "$(grep -c "\\\\033\\[r\\\\033\\[?6l\\\\033\\[3J\\\\033\\[H%s\\\\033\\[J" "$BOARD" | tr -d ' ')"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: ${total} total, ${pass} passed, ${fail} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ $fail -eq 0 ]] && exit 0 || exit 1
