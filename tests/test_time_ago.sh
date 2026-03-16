#!/usr/bin/env zsh
# Tests for _time_ago() utility function
set -euo pipefail
setopt KSH_ARRAYS

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOARD="$SCRIPT_DIR/../cloard-board"

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

# We need zsh/datetime for strftime and EPOCHSECONDS
zmodload zsh/datetime 2>/dev/null || true

# Extract just _time_ago function from the built script
eval "$(awk '/^_time_ago\(\)/{found=1} found{print} found && /^}$/{exit}' "$BOARD")"

echo "=== _time_ago() unit tests ==="

# ── A: Empty input ──────────────────────────────────────────────────────────
echo ""
echo "A. Empty / missing input"
_tago="DIRTY"
_time_ago ""
assert_eq "empty string clears _tago" "" "$_tago"

_tago="DIRTY"
_time_ago
assert_eq "no argument clears _tago" "" "$_tago"

# ── B: Recent timestamps ───────────────────────────────────────────────────
echo ""
echo "B. Recent timestamps"

# 30 seconds ago -> [<1m ago]
local ts_30s
TZ=UTC strftime -s ts_30s "%Y-%m-%dT%H:%M:%SZ" $((EPOCHSECONDS - 30))
_time_ago "$ts_30s"
assert_eq "30s ago -> [<1m ago]" "[<1m ago]" "$_tago"

# 5 seconds ago -> [<1m ago]
local ts_5s
TZ=UTC strftime -s ts_5s "%Y-%m-%dT%H:%M:%SZ" $((EPOCHSECONDS - 5))
_time_ago "$ts_5s"
assert_eq "5s ago -> [<1m ago]" "[<1m ago]" "$_tago"

# ── C: Minutes ─────────────────────────────────────────────────────────────
echo ""
echo "C. Minutes"

# 5 minutes ago
local ts_5m
TZ=UTC strftime -s ts_5m "%Y-%m-%dT%H:%M:%SZ" $((EPOCHSECONDS - 300))
_time_ago "$ts_5m"
assert_eq "5m ago -> [5m ago]" "[5m ago]" "$_tago"

# 1 minute ago
local ts_1m
TZ=UTC strftime -s ts_1m "%Y-%m-%dT%H:%M:%SZ" $((EPOCHSECONDS - 60))
_time_ago "$ts_1m"
assert_eq "1m ago -> [1m ago]" "[1m ago]" "$_tago"

# 59 minutes ago
local ts_59m
TZ=UTC strftime -s ts_59m "%Y-%m-%dT%H:%M:%SZ" $((EPOCHSECONDS - 3540))
_time_ago "$ts_59m"
assert_eq "59m ago -> [59m ago]" "[59m ago]" "$_tago"

# ── D: Hours ───────────────────────────────────────────────────────────────
echo ""
echo "D. Hours"

# 90 minutes ago -> 1h
local ts_90m
TZ=UTC strftime -s ts_90m "%Y-%m-%dT%H:%M:%SZ" $((EPOCHSECONDS - 5400))
_time_ago "$ts_90m"
assert_eq "90m ago -> [1h ago]" "[1h ago]" "$_tago"

# 3 hours ago
local ts_3h
TZ=UTC strftime -s ts_3h "%Y-%m-%dT%H:%M:%SZ" $((EPOCHSECONDS - 10800))
_time_ago "$ts_3h"
assert_eq "3h ago -> [3h ago]" "[3h ago]" "$_tago"

# 23 hours ago
local ts_23h
TZ=UTC strftime -s ts_23h "%Y-%m-%dT%H:%M:%SZ" $((EPOCHSECONDS - 82800))
_time_ago "$ts_23h"
assert_eq "23h ago -> [23h ago]" "[23h ago]" "$_tago"

# ── E: Days ────────────────────────────────────────────────────────────────
echo ""
echo "E. Days"

# 2 days ago
local ts_2d
TZ=UTC strftime -s ts_2d "%Y-%m-%dT%H:%M:%SZ" $((EPOCHSECONDS - 172800))
_time_ago "$ts_2d"
assert_eq "2d ago -> [2d ago]" "[2d ago]" "$_tago"

# 7 days ago
local ts_7d
TZ=UTC strftime -s ts_7d "%Y-%m-%dT%H:%M:%SZ" $((EPOCHSECONDS - 604800))
_time_ago "$ts_7d"
assert_eq "7d ago -> [7d ago]" "[7d ago]" "$_tago"

# ── F: Edge cases ──────────────────────────────────────────────────────────
echo ""
echo "F. Edge cases"

# Invalid timestamp
_tago="DIRTY"
_time_ago "not-a-date"
assert_eq "invalid timestamp -> empty" "" "$_tago"

# Future timestamp (1 hour ahead)
local ts_future
TZ=UTC strftime -s ts_future "%Y-%m-%dT%H:%M:%SZ" $((EPOCHSECONDS + 3600))
_tago="DIRTY"
_time_ago "$ts_future"
assert_eq "future timestamp -> empty" "" "$_tago"

# Exactly 0 seconds ago (now)
local ts_now
TZ=UTC strftime -s ts_now "%Y-%m-%dT%H:%M:%SZ" $EPOCHSECONDS
_time_ago "$ts_now"
assert_eq "now -> [<1m ago]" "[<1m ago]" "$_tago"

# Exactly 60 seconds ago (boundary: should be 1m, not <1m)
local ts_60s
TZ=UTC strftime -s ts_60s "%Y-%m-%dT%H:%M:%SZ" $((EPOCHSECONDS - 60))
_time_ago "$ts_60s"
assert_eq "60s ago -> [1m ago]" "[1m ago]" "$_tago"

# Exactly 3600 seconds ago (boundary: should be 1h, not 60m)
local ts_3600s
TZ=UTC strftime -s ts_3600s "%Y-%m-%dT%H:%M:%SZ" $((EPOCHSECONDS - 3600))
_time_ago "$ts_3600s"
assert_eq "3600s ago -> [1h ago]" "[1h ago]" "$_tago"

# Exactly 86400 seconds ago (boundary: should be 1d, not 24h)
local ts_86400s
TZ=UTC strftime -s ts_86400s "%Y-%m-%dT%H:%M:%SZ" $((EPOCHSECONDS - 86400))
_time_ago "$ts_86400s"
assert_eq "86400s ago -> [1d ago]" "[1d ago]" "$_tago"

# ── G: Signal handler updates last_activity_at ────────────────────────────
echo ""
echo "G. Signal handler updates last_activity_at"

# Helper to run zsh snippets against the built board
TMPDIR_TEST=$(mktemp -d)
trap "rm -rf $TMPDIR_TEST" EXIT

BOARD_SRC="$TMPDIR_TEST/board_src.zsh"
sed -e '/^main "\$@"$/d' \
    -e 's/^readonly GLOBAL_DIR=.*/GLOBAL_DIR="${GLOBAL_DIR:-\/tmp}"/' \
    -e 's/^readonly GLOBAL_STATE=.*/GLOBAL_STATE="${GLOBAL_STATE:-\/tmp\/state.json}"/' \
    -e 's/^readonly HOOKS_DIR=.*/HOOKS_DIR="${HOOKS_DIR:-\/tmp\/hooks}"/' \
    "$BOARD" > "$BOARD_SRC"

run_zsh() {
  local script="$TMPDIR_TEST/test_$$.zsh"
  cat > "$script"
  zsh "$script" "$BOARD" "$BOARD_SRC" 2>/dev/null
}

# G1: working signal sets last_activity_at
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":5,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","status_changed_at":"2026-01-01T00:00:00Z","claude_status":null}],"cron_jobs":[],"cron_runs":[]}
JSON
cmd_signal "t-001" "working"
jq -r '.tasks[0].last_activity_at // "null"' "$GLOBAL_STATE"
SCRIPT
)
total=$((total + 1))
if [[ "$result" != "null" && "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
  echo "  ✓ working signal sets last_activity_at"
  pass=$((pass + 1))
else
  echo "  ✗ working signal sets last_activity_at"
  echo "    got: $result"
  fail=$((fail + 1))
fi

# G2: waiting signal sets last_activity_at
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":5,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","status_changed_at":"2026-01-01T00:00:00Z","claude_status":"working"}],"cron_jobs":[],"cron_runs":[]}
JSON
cmd_signal "t-001" "waiting"
jq -r '.tasks[0].last_activity_at // "null"' "$GLOBAL_STATE"
SCRIPT
)
total=$((total + 1))
if [[ "$result" != "null" && "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
  echo "  ✓ waiting signal sets last_activity_at"
  pass=$((pass + 1))
else
  echo "  ✗ waiting signal sets last_activity_at"
  echo "    got: $result"
  fail=$((fail + 1))
fi

# G3: clear signal does NOT set last_activity_at
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":5,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","status_changed_at":"2026-01-01T00:00:00Z","claude_status":"working"}],"cron_jobs":[],"cron_runs":[]}
JSON
cmd_signal "t-001" "clear"
jq -r '.tasks[0].last_activity_at // "null"' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "clear signal does not set last_activity_at" "null" "$result"

# ── H: Snapshot includes _task_activity_at ────────────────────────────────
echo ""
echo "H. Snapshot includes _task_activity_at"

# H1: snapshot populates _task_activity_at when present
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":5,"next_task_id":2,"repos":[{"name":"r","path":"/tmp/r","type":"dir"}],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","status_changed_at":"2026-01-01T00:00:00Z","last_activity_at":"2026-03-15T10:30:00Z","claude_status":null,"worktree_mode":"none","pr_url":null}],"cron_jobs":[],"cron_runs":[]}
JSON
typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_paths _repo_types _repo_stale _repo_task_count
typeset -A _repo_cols _repo_col_cnt
local -a _repo_names
local _total_task_count=0 _active_count=0 _review_count=0
typeset -A _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _cron_col_ids _cron_col_cnt
local _has_cron_data=false
local _ci
for _ci in {0..3}; do
  _cron_col_ids["__cron:${_ci}"]=""
  _cron_col_cnt["__cron:${_ci}"]=0
done

_snapshot_tasks
echo "${_task_activity_at[t-001]}"
SCRIPT
)
assert_eq "snapshot populates _task_activity_at" "2026-03-15T10:30:00Z" "$result"

# H2: snapshot gives empty string when last_activity_at missing
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":5,"next_task_id":2,"repos":[{"name":"r","path":"/tmp/r","type":"dir"}],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","status_changed_at":"2026-01-01T00:00:00Z","claude_status":null,"worktree_mode":"none","pr_url":null}],"cron_jobs":[],"cron_runs":[]}
JSON
typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_paths _repo_types _repo_stale _repo_task_count
typeset -A _repo_cols _repo_col_cnt
local -a _repo_names
local _total_task_count=0 _active_count=0 _review_count=0
typeset -A _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _cron_col_ids _cron_col_cnt
local _has_cron_data=false
local _ci
for _ci in {0..3}; do
  _cron_col_ids["__cron:${_ci}"]=""
  _cron_col_cnt["__cron:${_ci}"]=0
done

_snapshot_tasks
echo "empty:${#_task_activity_at[t-001]}"
SCRIPT
)
assert_eq "missing last_activity_at gives empty" "empty:0" "$result"

# ── I: Fallback logic ────────────────────────────────────────────────────
echo ""
echo "I. Fallback: activity_at preferred over status_at"

# I1: Source code uses _task_activity_at with fallback
grep -q '_task_activity_at\[' "$BOARD"
assert_eq "_task_activity_at array used in source" "0" "$?"

grep -q '_task_activity_at\[$task_id\]:-\${_task_status_at' "$BOARD"
assert_eq "fallback pattern present in source" "0" "$?"

# I2: sidebar render uses time ago
grep -q '_time_ago.*_render_sidebar_task_card\|_render_sidebar_task_card.*_time_ago' "$BOARD" || \
  grep -A 30 '_render_sidebar_task_card()' "$BOARD" | grep -q '_time_ago'
assert_eq "sidebar card calls _time_ago" "0" "$?"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: ${pass}/${total} passed ==="
[[ $fail -eq 0 ]] || exit 1
