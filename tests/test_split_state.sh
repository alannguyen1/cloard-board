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

reset_tmux() {
  tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true
  ensure_tmux_session
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

BOARD_SRC="$TMPDIR_TEST/board_src.zsh"
sed \
  -e '/^main "\$@"$/d' \
  -e 's|^readonly TMUX_SOCKET=.*|readonly TMUX_SOCKET="${TMUX_SOCKET:-cloard-board}"|' \
  -e 's|^readonly GLOBAL_DIR=.*|readonly GLOBAL_DIR="${GLOBAL_DIR:-/tmp}"|' \
  -e 's|^readonly GLOBAL_STATE=.*|readonly GLOBAL_STATE="${GLOBAL_STATE:-$GLOBAL_DIR/state.json}"|' \
  -e 's|^readonly HOOKS_DIR=.*|readonly HOOKS_DIR="${HOOKS_DIR:-$GLOBAL_DIR/hooks}"|' \
  "$BOARD" > "$BOARD_SRC"

source "$BOARD_SRC"

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
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: ${total} total, ${pass} passed, ${fail} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ $fail -eq 0 ]] && exit 0 || exit 1
