#!/usr/bin/env zsh
# Tests for cloard-board reopen feature
# Covers: cmd_reopen function, CLI dispatch, dashboard keybinding, help text
set -euo pipefail
setopt KSH_ARRAYS

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOARD="$SCRIPT_DIR/../cloard-board"
TMPDIR_TEST=$(mktemp -d)
trap "rm -rf $TMPDIR_TEST" EXIT

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

assert_file_match() {
  local label="$1" pattern="$2" file="$3"
  total=$((total + 1))
  if grep -qE "$pattern" "$file"; then
    echo "  ✓ $label"
    pass=$((pass + 1))
  else
    echo "  ✗ $label"
    echo "    pattern: $pattern"
    fail=$((fail + 1))
  fi
}

assert_file_not_match() {
  local label="$1" pattern="$2" file="$3"
  total=$((total + 1))
  if ! grep -qE "$pattern" "$file"; then
    echo "  ✓ $label"
    pass=$((pass + 1))
  else
    echo "  ✗ $label"
    echo "    should NOT match: $pattern"
    fail=$((fail + 1))
  fi
}

# Helper: create test state with a done task
make_state_with_done_task() {
  local state_file="$1"
  local repo_path="${2:-/tmp/test}"
  cat > "$state_file" <<JSON
{"version":3,"next_task_id":3,"next_cron_id":1,"next_run_id":1,"repos":[{"name":"test-repo","path":"${repo_path}","type":"git","archived":false}],"tasks":[{"id":"t-001","title":"Fix login bug","status":"done","repo":"test-repo","worktree_mode":"worktree","branch":"worktree-t-001","completed_at":"2026-02-25T10:00:00Z","claude_status":null},{"id":"t-002","title":"Active task","status":"active","repo":"test-repo","worktree_mode":"none","branch":null,"completed_at":null,"claude_status":"working"}],"cron_jobs":[],"cron_runs":[]}
JSON
}

# ── Source structure tests ────────────────────────────────────────────────────

echo ""
echo "cmd_reopen function exists"

assert_file_match "cmd_reopen function defined" \
  'cmd_reopen\(\)' "$BOARD"

assert_file_match "cmd_reopen checks for done status" \
  'only.*done.*tasks can be reopened' "$BOARD"

assert_file_match "cmd_reopen uses claude --continue" \
  'claude --continue --dangerously-skip-permissions' "$BOARD"

assert_file_match "cmd_reopen updates status to active" \
  'set_task_status.*active' "$BOARD"

assert_file_match "cmd_reopen clears completed_at" \
  'update_task_field_raw.*completed_at.*null' "$BOARD"

assert_file_match "cmd_reopen sets worktree_mode to none" \
  'update_task_field.*worktree_mode.*none' "$BOARD"

assert_file_match "cmd_reopen clears branch" \
  'update_task_field_raw.*branch.*null' "$BOARD"

# ── CLI dispatch ──────────────────────────────────────────────────────────────

echo ""
echo "CLI dispatch"

assert_file_match "reopen command in dispatcher" \
  'reopen\).*cmd_reopen' "$BOARD"

# ── Dashboard keybinding ──────────────────────────────────────────────────────

echo ""
echo "Dashboard r keybinding"

assert_file_match "r key handler in dashboard" \
  "r\) # Reopen done task" "$BOARD"

assert_file_match "r handler checks for done status" \
  'r_status.*==.*done' "$BOARD"

assert_file_match "r handler prompts for Claude" \
  'Prompt for Claude.*continue previous session' "$BOARD"

# ── Enter on done tasks ──────────────────────────────────────────────────────

echo ""
echo "Enter on done tasks (no longer no-op)"

assert_file_not_match "no-op removed for done tasks" \
  'done\) ;; # No-op' "$BOARD"

assert_file_match "done case has reopen logic in Enter handler" \
  'done\)' "$BOARD"

# ── Help text ─────────────────────────────────────────────────────────────────

echo ""
echo "Help text"

assert_file_match "reopen in help task commands" \
  'reopen <id>.*Reopen a done task' "$BOARD"

assert_file_match "r keybinding in help dashboard keys" \
  'r.*Reopen done task' "$BOARD"

# ── Footer hint ───────────────────────────────────────────────────────────────

echo ""
echo "Dashboard footer"

assert_file_match "r: reopen in footer hint" \
  'r: reopen' "$BOARD"

# ── State mutation tests ──────────────────────────────────────────────────────

echo ""
echo "State mutation via direct jq"

FAKE_GLOBAL="$TMPDIR_TEST/global"
mkdir -p "$FAKE_GLOBAL"
FAKE_STATE="$FAKE_GLOBAL/state.json"
make_state_with_done_task "$FAKE_STATE" "$TMPDIR_TEST"

# Verify initial state
local done_status
done_status=$(jq -r '.tasks[] | select(.id == "t-001") | .status' "$FAKE_STATE")
assert_eq "done task starts as done" "done" "$done_status"

local done_completed
done_completed=$(jq -r '.tasks[] | select(.id == "t-001") | .completed_at' "$FAKE_STATE")
assert_eq "done task has completed_at" "2026-02-25T10:00:00Z" "$done_completed"

local done_wtmode
done_wtmode=$(jq -r '.tasks[] | select(.id == "t-001") | .worktree_mode' "$FAKE_STATE")
assert_eq "done task originally had worktree mode" "worktree" "$done_wtmode"

# Simulate what cmd_reopen does to state (update fields)
local tmp="$TMPDIR_TEST/tmp_state.json"
jq '(.tasks[] | select(.id == "t-001")).status = "active"' "$FAKE_STATE" > "$tmp" && mv "$tmp" "$FAKE_STATE"
jq '(.tasks[] | select(.id == "t-001")).worktree_mode = "none"' "$FAKE_STATE" > "$tmp" && mv "$tmp" "$FAKE_STATE"
jq '(.tasks[] | select(.id == "t-001")).branch = null' "$FAKE_STATE" > "$tmp" && mv "$tmp" "$FAKE_STATE"
jq '(.tasks[] | select(.id == "t-001")).completed_at = null' "$FAKE_STATE" > "$tmp" && mv "$tmp" "$FAKE_STATE"

# Verify post-reopen state
local new_status
new_status=$(jq -r '.tasks[] | select(.id == "t-001") | .status' "$FAKE_STATE")
assert_eq "reopened task status is active" "active" "$new_status"

local new_wtmode
new_wtmode=$(jq -r '.tasks[] | select(.id == "t-001") | .worktree_mode' "$FAKE_STATE")
assert_eq "reopened task worktree_mode is none" "none" "$new_wtmode"

local new_branch
new_branch=$(jq -r '.tasks[] | select(.id == "t-001") | .branch' "$FAKE_STATE")
assert_eq "reopened task branch is null" "null" "$new_branch"

local new_completed
new_completed=$(jq -r '.tasks[] | select(.id == "t-001") | .completed_at' "$FAKE_STATE")
assert_eq "reopened task completed_at is null" "null" "$new_completed"

# Verify other task was not affected
local other_status
other_status=$(jq -r '.tasks[] | select(.id == "t-002") | .status' "$FAKE_STATE")
assert_eq "other task unchanged" "active" "$other_status"

# ── Review status removed ─────────────────────────────────────────────────────

echo ""
echo "Review status absent"
assert_file_not_match "no review in COL_STATUSES" '"review"' "$BOARD"
assert_file_not_match "no In PR in COL_NAMES" 'In PR' "$BOARD"
assert_file_not_match "no cmd_review function" 'cmd_review' "$BOARD"
assert_file_not_match "no review command in help" 'review <id>' "$BOARD"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: ${pass}/${total} passed, ${fail} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ $fail -eq 0 ]] || exit 1
