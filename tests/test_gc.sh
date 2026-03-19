#!/usr/bin/env zsh
# Functional tests for task runtime GC and diagnostics.
set -euo pipefail
setopt KSH_ARRAYS

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOARD="$SCRIPT_DIR/../cloard-board"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass=0
fail=0
total=0

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

assert_match() {
  local label="$1" pattern="$2" actual="$3"
  total=$((total + 1))
  if [[ "$actual" =~ $pattern ]]; then
    echo "  ✓ $label"
    pass=$((pass + 1))
  else
    echo "  ✗ $label"
    echo "    pattern: $pattern"
    echo "    actual:  $(printf '%q' "$actual")"
    fail=$((fail + 1))
  fi
}

hours_ago_iso() {
  local hours="$1"
  date -u -v-"${hours}"H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "${hours} hours ago" +"%Y-%m-%dT%H:%M:%SZ"
}

minutes_ago_iso() {
  local minutes="$1"
  date -u -v-"${minutes}"M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "${minutes} minutes ago" +"%Y-%m-%dT%H:%M:%SZ"
}

echo "=== Task runtime GC ==="

export TMUX_SOCKET="cloard-board-gc-$$"
export GLOBAL_DIR="$TMPDIR_TEST/global"
export GLOBAL_STATE="$GLOBAL_DIR/state.json"
export HOOKS_DIR="$GLOBAL_DIR/hooks"
mkdir -p "$HOOKS_DIR"

BOARD_SRC="$TMPDIR_TEST/board_src.zsh"
sed \
  -e '/^main "\$@"$/d' \
  -e 's|^readonly TMUX_SOCKET=.*|readonly TMUX_SOCKET="${TMUX_SOCKET:-cloard-board}"|' \
  -e 's|^readonly GLOBAL_DIR=.*|readonly GLOBAL_DIR="${GLOBAL_DIR:-/tmp}"|' \
  -e 's|^readonly GLOBAL_STATE=.*|readonly GLOBAL_STATE="${GLOBAL_STATE:-$GLOBAL_DIR/state.json}"|' \
  -e 's|^readonly HOOKS_DIR=.*|readonly HOOKS_DIR="${HOOKS_DIR:-$GLOBAL_DIR/hooks}"|' \
  "$BOARD" > "$BOARD_SRC"

source "$BOARD_SRC"
trap 'tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true; rm -rf "$TMPDIR_TEST"' EXIT

old_review_at=$(hours_ago_iso 2)
old_active_at=$(hours_ago_iso 26)
recent_active_at=$(minutes_ago_iso 5)
done_at=$(hours_ago_iso 3)

cat > "$GLOBAL_STATE" <<JSON
{"version":5,"next_task_id":7,"repos":[],"tasks":[
  {"id":"t-001","title":"done live","repo":"r","status":"done","created_at":"$done_at","started_at":"$done_at","completed_at":"$done_at","status_changed_at":"$done_at","claude_status":null,"worktree_mode":"none","session_uid":"uid-001","session_history":["uid-001"]},
  {"id":"t-002","title":"done shell","repo":"r","status":"done","created_at":"$done_at","started_at":"$done_at","completed_at":"$done_at","status_changed_at":"$done_at","claude_status":null,"worktree_mode":"none","session_uid":"uid-002","session_history":["uid-002"]},
  {"id":"t-003","title":"review runtime","repo":"r","status":"needs_review","created_at":"$old_review_at","started_at":"$old_review_at","completed_at":null,"status_changed_at":"$old_review_at","last_activity_at":"$old_review_at","claude_status":"waiting","worktree_mode":"none","session_uid":"uid-003","session_history":["uid-003"]},
  {"id":"t-004","title":"active idle","repo":"r","status":"active","created_at":"$old_active_at","started_at":"$old_active_at","completed_at":null,"status_changed_at":"$old_active_at","last_activity_at":"$old_active_at","claude_status":"working","worktree_mode":"none","session_uid":"uid-004","session_history":["uid-004"]},
  {"id":"t-005","title":"active recent","repo":"r","status":"active","created_at":"$recent_active_at","started_at":"$recent_active_at","completed_at":null,"status_changed_at":"$recent_active_at","last_activity_at":"$recent_active_at","claude_status":"working","worktree_mode":"none","session_uid":"uid-005","session_history":["uid-005"]},
  {"id":"t-006","title":"done split","repo":"r","status":"done","created_at":"$done_at","started_at":"$done_at","completed_at":"$done_at","status_changed_at":"$done_at","claude_status":null,"worktree_mode":"none","session_uid":"uid-006","session_history":["uid-006"]}
],"cron_jobs":[],"cron_runs":[]}
JSON

tmux_cmd new-session -d -s "board" -n "dashboard"
tmux_cmd new-window -t "board" -n "t-001" "zsh -c 'export CLOARD_TASK_ID=t-001; node -e \"setInterval(function(){}, 1000000)\"'"
tmux_cmd new-window -t "board" -n "t-002" "zsh -c 'export CLOARD_TASK_ID=t-002; zsh'"
tmux_cmd new-window -t "board" -n "t-003" "zsh -c 'export CLOARD_TASK_ID=t-003; node -e \"setInterval(function(){}, 1000000)\"'"
tmux_cmd new-window -t "board" -n "t-004" "zsh -c 'export CLOARD_TASK_ID=t-004; node -e \"setInterval(function(){}, 1000000)\"'"
tmux_cmd new-window -t "board" -n "t-005" "zsh -c 'export CLOARD_TASK_ID=t-005; node -e \"setInterval(function(){}, 1000000)\"'"
tmux_cmd split-window -h -t "board:dashboard" "zsh -c 'export CLOARD_TASK_ID=t-006; node -e \"setInterval(function(){}, 1000000)\"'"
_tmux_mark_task_pane "board:dashboard.1" "t-006"
sleep 1

doctor_before=$(cmd_doctor 2>&1 || true)
cmd_gc >/dev/null
sleep 1
doctor_after=$(cmd_doctor 2>&1 || true)

echo ""
echo "A. Doctor reports drift before GC"
assert_match "doctor reports live session count" 'live Claude sessions:' "$doctor_before"
assert_match "doctor flags done runtime" "t-001" "$doctor_before"
assert_match "doctor flags needs_review runtime" "t-003" "$doctor_before"
assert_match "doctor flags idle active task" "t-004" "$doctor_before"

echo ""
echo "B. GC removes stale and invariant-breaking runtimes"
assert_eq "done live window removed" "absent" "$(tmux_window_exists "t-001" && echo present || echo absent)"
assert_eq "done stale shell window removed" "absent" "$(tmux_window_exists "t-002" && echo present || echo absent)"
assert_eq "needs_review runtime removed" "absent" "$(tmux_window_exists "t-003" && echo present || echo absent)"
assert_eq "idle active runtime removed" "absent" "$(tmux_window_exists "t-004" && echo present || echo absent)"
assert_eq "recent active window preserved" "present" "$(tmux_window_exists "t-005" && echo present || echo absent)"
assert_eq "dashboard split cleaned up" "1" "$(tmux_cmd list-panes -t "board:dashboard" 2>/dev/null | wc -l | tr -d ' ')"

echo ""
echo "C. GC preserves and updates task state correctly"
assert_eq "done live task stays done" "done" "$(task_status "t-001")"
assert_eq "done shell task stays done" "done" "$(task_status "t-002")"
assert_eq "needs_review task stays needs_review" "needs_review" "$(task_status "t-003")"
assert_eq "idle active task pauses" "paused" "$(task_status "t-004")"
assert_eq "recent active task stays active" "active" "$(task_status "t-005")"
assert_eq "split task stays done" "done" "$(task_status "t-006")"
assert_eq "idle active claude_status cleared" "null" "$(jq -r '.tasks[] | select(.id == "t-004") | .claude_status' "$GLOBAL_STATE")"
assert_eq "live session count reduced to one" "1" "$(_tmux_live_session_count)"

echo ""
echo "D. Doctor is clean after GC"
assert_match "doctor reports all clear after gc" 'all clear; no issues found' "$doctor_after"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: ${total} total, ${pass} passed, ${fail} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ $fail -eq 0 ]] && exit 0 || exit 1
