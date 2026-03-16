#!/usr/bin/env zsh
# Tests for status_changed_at feature:
#   A: set_task_status function
#   B: Migration v4 -> v5
#   C: Snapshot includes status_changed_at
#   D: List mode sort by status_changed_at within priority groups
#   E: Task creation includes status_changed_at
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

assert_match() {
  local label="$1" pattern="$2" actual="$3"
  total=$((total + 1))
  if echo "$actual" | grep -qE "$pattern"; then
    echo "  ✓ $label"
    pass=$((pass + 1))
  else
    echo "  ✗ $label"
    echo "    expected pattern: $pattern"
    echo "    actual: $(printf '%q' "$actual")"
    fail=$((fail + 1))
  fi
}

assert_ne() {
  local label="$1" unexpected="$2" actual="$3"
  total=$((total + 1))
  if [[ "$unexpected" != "$actual" ]]; then
    echo "  ✓ $label"
    pass=$((pass + 1))
  else
    echo "  ✗ $label"
    echo "    should not equal: $(printf '%q' "$unexpected")"
    fail=$((fail + 1))
  fi
}

# Helper: run a zsh snippet from a temp file
run_zsh() {
  local script="$TMPDIR_TEST/test_$$.zsh"
  cat > "$script"
  zsh "$script" "$BOARD" "$BOARD_SRC" 2>/dev/null
}

# Extract sourceable version of built script
BOARD_SRC="$TMPDIR_TEST/board_src.zsh"
sed -e '/^main "\$@"$/d' \
    -e 's/^readonly GLOBAL_DIR=.*/GLOBAL_DIR="${GLOBAL_DIR:-\/tmp}"/' \
    -e 's/^readonly GLOBAL_STATE=.*/GLOBAL_STATE="${GLOBAL_STATE:-\/tmp\/state.json}"/' \
    -e 's/^readonly HOOKS_DIR=.*/HOOKS_DIR="${HOOKS_DIR:-\/tmp\/hooks}"/' \
    "$BOARD" > "$BOARD_SRC"

# ── A: set_task_status function ──────────────────────────────────────────────

echo ""
echo "A: set_task_status"

# A1: set_task_status updates both status and status_changed_at
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":5,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"pending","status_changed_at":"2026-01-01T00:00:00Z"}],"cron_jobs":[],"cron_runs":[]}
JSON
set_task_status "t-001" "active"
jq -r '.tasks[0].status' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "set_task_status updates status" "active" "$result"

# A2: set_task_status updates timestamp
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":5,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"pending","status_changed_at":"2026-01-01T00:00:00Z"}],"cron_jobs":[],"cron_runs":[]}
JSON
set_task_status "t-001" "active"
jq -r '.tasks[0].status_changed_at' "$GLOBAL_STATE"
SCRIPT
)
assert_ne "set_task_status updates timestamp" "2026-01-01T00:00:00Z" "$result"
assert_match "timestamp is ISO format" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$result"

# A3: set_task_status preserves other fields
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":5,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"keep this","repo":"myrepo","status":"pending","status_changed_at":"2026-01-01T00:00:00Z","claude_status":null}],"cron_jobs":[],"cron_runs":[]}
JSON
set_task_status "t-001" "done"
jq -r '.tasks[0] | [.title, .repo] | join(",")' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "set_task_status preserves other fields" "keep this,myrepo" "$result"

# A4: set_task_status only affects targeted task
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":5,"next_task_id":3,"repos":[],"tasks":[{"id":"t-001","title":"first","repo":"r","status":"pending","status_changed_at":"2026-01-01T00:00:00Z"},{"id":"t-002","title":"second","repo":"r","status":"active","status_changed_at":"2026-01-02T00:00:00Z"}],"cron_jobs":[],"cron_runs":[]}
JSON
set_task_status "t-001" "active"
jq -r '.tasks[1].status' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "set_task_status does not affect other tasks" "active" "$result"

# ── B: Migration v4 -> v5 ───────────────────────────────────────────────────

echo ""
echo "B: Migration v4 -> v5"

# B1: Done task gets completed_at as status_changed_at
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"done task","repo":"r","status":"done","created_at":"2026-01-01T00:00:00Z","started_at":"2026-01-02T00:00:00Z","completed_at":"2026-01-03T00:00:00Z","session_history":[]}],"cron_jobs":[],"cron_runs":[]}
JSON
_migrate_v4_to_v5 >/dev/null
jq -r '.tasks[0].status_changed_at' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "done task uses completed_at" "2026-01-03T00:00:00Z" "$result"

# B2: Active task gets started_at as status_changed_at
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"active task","repo":"r","status":"active","created_at":"2026-01-01T00:00:00Z","started_at":"2026-01-02T00:00:00Z","completed_at":null,"session_history":[]}],"cron_jobs":[],"cron_runs":[]}
JSON
_migrate_v4_to_v5 >/dev/null
jq -r '.tasks[0].status_changed_at' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "active task uses started_at" "2026-01-02T00:00:00Z" "$result"

# B3: Pending task falls back to created_at
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"pending task","repo":"r","status":"pending","created_at":"2026-01-01T00:00:00Z","started_at":null,"completed_at":null,"session_history":[]}],"cron_jobs":[],"cron_runs":[]}
JSON
_migrate_v4_to_v5 >/dev/null
jq -r '.tasks[0].status_changed_at' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "pending task uses created_at" "2026-01-01T00:00:00Z" "$result"

# B4: Version bumped to 5
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":1,"repos":[],"tasks":[],"cron_jobs":[],"cron_runs":[]}
JSON
_migrate_v4_to_v5 >/dev/null
jq -r '.version' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "version bumped to 5" "5" "$result"

# B5: Paused task uses started_at
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"paused","repo":"r","status":"paused","created_at":"2026-01-01T00:00:00Z","started_at":"2026-01-05T00:00:00Z","completed_at":null,"session_history":[]}],"cron_jobs":[],"cron_runs":[]}
JSON
_migrate_v4_to_v5 >/dev/null
jq -r '.tasks[0].status_changed_at' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "paused task uses started_at" "2026-01-05T00:00:00Z" "$result"

# B6: needs_review task uses started_at
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"review","repo":"r","status":"needs_review","created_at":"2026-01-01T00:00:00Z","started_at":"2026-01-04T00:00:00Z","completed_at":null,"session_history":[]}],"cron_jobs":[],"cron_runs":[]}
JSON
_migrate_v4_to_v5 >/dev/null
jq -r '.tasks[0].status_changed_at' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "needs_review task uses started_at" "2026-01-04T00:00:00Z" "$result"

# B7: Full chain v3 -> v5 (call migrations directly to avoid hook side effects)
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":3,"next_task_id":2,"next_cron_id":1,"next_run_id":1,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":"abc","created_at":"2026-01-01T00:00:00Z","started_at":"2026-01-02T00:00:00Z"}],"cron_jobs":[],"cron_runs":[]}
JSON
_migrate_v3_to_v4 >/dev/null
_migrate_v4_to_v5 >/dev/null
echo "version=$(jq -r '.version' "$GLOBAL_STATE")"
echo "sca=$(jq -r '.tasks[0].status_changed_at' "$GLOBAL_STATE")"
echo "sh=$(jq -r '.tasks[0].session_history | length' "$GLOBAL_STATE")"
SCRIPT
)
v=$(echo "$result" | grep '^version=' | cut -d= -f2)
sca=$(echo "$result" | grep '^sca=' | cut -d= -f2)
sh=$(echo "$result" | grep '^sh=' | cut -d= -f2)
assert_eq "v3 to v5: version is 5" "5" "$v"
assert_eq "v3 to v5: status_changed_at populated" "2026-01-02T00:00:00Z" "$sca"
assert_eq "v3 to v5: session_history migrated" "1" "$sh"

# ── C: Snapshot includes status_changed_at ───────────────────────────────────

echo ""
echo "C: Snapshot includes status_changed_at"

result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":5,"next_task_id":2,"repos":[{"name":"r","path":"/tmp/r","type":"dir"}],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","status_changed_at":"2026-03-10T12:00:00Z","claude_status":null,"worktree_mode":"none","pr_url":null}],"cron_jobs":[],"cron_runs":[]}
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
echo "${_task_status_at[t-001]}"
SCRIPT
)
assert_eq "snapshot populates _task_status_at" "2026-03-10T12:00:00Z" "$result"

# C2: Missing status_changed_at gives empty string
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":5,"next_task_id":2,"repos":[{"name":"r","path":"/tmp/r","type":"dir"}],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","claude_status":null,"worktree_mode":"none","pr_url":null}],"cron_jobs":[],"cron_runs":[]}
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
echo "empty:${#_task_status_at[t-001]}"
SCRIPT
)
assert_eq "missing status_changed_at gives empty" "empty:0" "$result"

# ── D: Sort within priority groups ──────────────────────────────────────────

echo ""
echo "D: Sort by status_changed_at within priority groups"

# D1: Two active tasks sorted by status_changed_at (newest first)
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_cols _repo_col_cnt _repo_task_count _repo_stale
typeset -A _cron_col_ids _cron_col_cnt _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _list_group_collapsed
local -a _repo_names _list_items
local _show_done=0 _list_cursor=0 _list_follow_id="" _has_cron_data=false
local _total_task_count=0 _active_count=0 _review_count=0

_repo_names=("test-repo")
_repo_task_count[test-repo]=3
_repo_cols[test-repo:0]=""
_repo_cols[test-repo:1]="t-001 t-002 t-003"
_repo_cols[test-repo:2]=""
_repo_cols[test-repo:3]=""
_repo_col_cnt[test-repo:0]=0
_repo_col_cnt[test-repo:1]=3
_repo_col_cnt[test-repo:2]=0
_repo_col_cnt[test-repo:3]=0

_task_status[t-001]="active"; _task_claude[t-001]=""
_task_status[t-002]="active"; _task_claude[t-002]=""
_task_status[t-003]="active"; _task_claude[t-003]=""

# t-003 most recent, t-001 least recent
_task_status_at[t-001]="2026-01-01T00:00:00Z"
_task_status_at[t-002]="2026-02-15T00:00:00Z"
_task_status_at[t-003]="2026-03-10T00:00:00Z"

for _ci in {0..3}; do _cron_col_ids[__cron:${_ci}]=""; _cron_col_cnt[__cron:${_ci}]=0; done

_list_build_items

for item in "${_list_items[@]}"; do echo "$item"; done
SCRIPT
)
expected=$(cat <<'EOF'
group:test-repo
task:t-003
task:t-002
task:t-001
cron_group:__cron
EOF
)
assert_eq "active tasks sorted newest first" "$expected" "$result"

# D2: Sort only within same priority group (cross-group order preserved)
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_cols _repo_col_cnt _repo_task_count _repo_stale
typeset -A _cron_col_ids _cron_col_cnt _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _list_group_collapsed
local -a _repo_names _list_items
local _show_done=0 _list_cursor=0 _list_follow_id="" _has_cron_data=false
local _total_task_count=0 _active_count=0 _review_count=0

_repo_names=("r")
_repo_task_count[r]=4
_repo_cols[r:0]="t-003 t-004"
_repo_cols[r:1]="t-001 t-002"
_repo_cols[r:2]=""
_repo_cols[r:3]=""
_repo_col_cnt[r:0]=2
_repo_col_cnt[r:1]=2
_repo_col_cnt[r:2]=0
_repo_col_cnt[r:3]=0

_task_status[t-001]="active"; _task_claude[t-001]=""
_task_status[t-002]="active"; _task_claude[t-002]=""
_task_status[t-003]="pending"; _task_claude[t-003]=""
_task_status[t-004]="pending"; _task_claude[t-004]=""

# Within active: t-002 newer; within pending: t-004 newer
_task_status_at[t-001]="2026-01-01T00:00:00Z"
_task_status_at[t-002]="2026-03-01T00:00:00Z"
_task_status_at[t-003]="2026-01-15T00:00:00Z"
_task_status_at[t-004]="2026-02-20T00:00:00Z"

for _ci in {0..3}; do _cron_col_ids[__cron:${_ci}]=""; _cron_col_cnt[__cron:${_ci}]=0; done

_list_build_items

for item in "${_list_items[@]}"; do echo "$item"; done
SCRIPT
)
expected=$(cat <<'EOF'
group:r
task:t-002
task:t-001
task:t-004
task:t-003
cron_group:__cron
EOF
)
assert_eq "sort within groups, active before pending" "$expected" "$result"

# D3: Single item in group (no sort needed, no crash)
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_cols _repo_col_cnt _repo_task_count _repo_stale
typeset -A _cron_col_ids _cron_col_cnt _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _list_group_collapsed
local -a _repo_names _list_items
local _show_done=0 _list_cursor=0 _list_follow_id="" _has_cron_data=false
local _total_task_count=0 _active_count=0 _review_count=0

_repo_names=("r")
_repo_task_count[r]=1
_repo_cols[r:0]=""
_repo_cols[r:1]="t-001"
_repo_cols[r:2]=""
_repo_cols[r:3]=""
_repo_col_cnt[r:0]=0
_repo_col_cnt[r:1]=1
_repo_col_cnt[r:2]=0
_repo_col_cnt[r:3]=0

_task_status[t-001]="active"; _task_claude[t-001]=""
_task_status_at[t-001]="2026-03-01T00:00:00Z"

for _ci in {0..3}; do _cron_col_ids[__cron:${_ci}]=""; _cron_col_cnt[__cron:${_ci}]=0; done

_list_build_items

for item in "${_list_items[@]}"; do echo "$item"; done
SCRIPT
)
expected=$(cat <<'EOF'
group:r
task:t-001
cron_group:__cron
EOF
)
assert_eq "single item group works" "$expected" "$result"

# D4: Missing status_changed_at sorts to end (empty < any timestamp)
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_cols _repo_col_cnt _repo_task_count _repo_stale
typeset -A _cron_col_ids _cron_col_cnt _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _list_group_collapsed
local -a _repo_names _list_items
local _show_done=0 _list_cursor=0 _list_follow_id="" _has_cron_data=false
local _total_task_count=0 _active_count=0 _review_count=0

_repo_names=("r")
_repo_task_count[r]=3
_repo_cols[r:0]="t-001 t-002 t-003"
_repo_cols[r:1]=""
_repo_cols[r:2]=""
_repo_cols[r:3]=""
_repo_col_cnt[r:0]=3
_repo_col_cnt[r:1]=0
_repo_col_cnt[r:2]=0
_repo_col_cnt[r:3]=0

_task_status[t-001]="pending"; _task_claude[t-001]=""
_task_status[t-002]="pending"; _task_claude[t-002]=""
_task_status[t-003]="pending"; _task_claude[t-003]=""

_task_status_at[t-001]="2026-03-01T00:00:00Z"
# t-002 has no status_changed_at (empty)
_task_status_at[t-003]="2026-01-01T00:00:00Z"

for _ci in {0..3}; do _cron_col_ids[__cron:${_ci}]=""; _cron_col_cnt[__cron:${_ci}]=0; done

_list_build_items

for item in "${_list_items[@]}"; do echo "$item"; done
SCRIPT
)
expected=$(cat <<'EOF'
group:r
task:t-001
task:t-003
task:t-002
cron_group:__cron
EOF
)
assert_eq "missing timestamp sorts to end" "$expected" "$result"

# ── E: Task creation includes status_changed_at ─────────────────────────────

echo ""
echo "E: Task creation"

# E1: Source structure check
grep -q 'status_changed_at' "$BOARD"
assert_eq "status_changed_at present in built script" "0" "$?"

grep -q 'set_task_status()' "$BOARD"
assert_eq "set_task_status function defined" "0" "$?"

grep -q '_sort_by_status_at()' "$BOARD"
assert_eq "_sort_by_status_at function defined" "0" "$?"

grep -q '_task_status_at' "$BOARD"
assert_eq "_task_status_at array used" "0" "$?"

grep -q '_migrate_v4_to_v5()' "$BOARD"
assert_eq "_migrate_v4_to_v5 function defined" "0" "$?"

# E2: No remaining update_task_field with status
! grep -q 'update_task_field.*"status"' "$BOARD"
assert_eq "no old update_task_field status calls remain" "0" "$?"

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════"
echo "status_changed_at: ${pass}/${total} passed, ${fail} failed"
echo "══════════════════════════════════════════════════"

[[ $fail -eq 0 ]] || exit 1
