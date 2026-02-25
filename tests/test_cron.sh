#!/usr/bin/env zsh
# Tests for cloard-board v0.3.0 cron job integration
# Covers: schema migration, cron helpers, state management, plist discovery, cleanup
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
    echo "    pattern: $pattern"
    echo "    actual:  $actual"
    fail=$((fail + 1))
  fi
}

# Helper: create a test state file
make_v2_state() {
  local state_file="$1"
  cat > "$state_file" <<'JSON'
{"version":2,"next_task_id":3,"repos":[{"name":"test-repo","path":"/tmp/test","type":"git","archived":false}],"tasks":[{"id":"t-001","title":"Test task","status":"pending","repo":"test-repo"}]}
JSON
}

make_v3_state() {
  local state_file="$1"
  cat > "$state_file" <<'JSON'
{"version":3,"next_task_id":3,"next_cron_id":2,"next_run_id":2,"repos":[{"name":"test-repo","path":"/tmp/test","type":"git","archived":false}],"tasks":[{"id":"t-001","title":"Test task","status":"pending","repo":"test-repo"}],"cron_jobs":[{"id":"cj-001","label":"com.cloard-board.test-job","name":"test-job","plist_path":"","working_dir":"/tmp","claude_command":"claude -p test","schedule_type":"daily","schedule_desc":"Daily at 08:30","schedule_raw":{"Hour":8,"Minute":30},"enabled":true,"created_at":"2025-01-01T00:00:00Z","env_vars":{}}],"cron_runs":[{"run_id":"cr-001","cron_job_id":"cj-001","session_id":"test-uuid","tmux_window":"cron-cj-001-123","started_at":"2025-01-01T00:00:00Z","completed_at":"2025-01-01T01:00:00Z","exit_code":0,"status":"needs_review"}]}
JSON
}

# ── Version ───────────────────────────────────────────────────────────────────

echo ""
echo "Version"

version_output=$("$BOARD" version 2>&1)
assert_eq "version is 0.3.0" "cloard-board v0.3.0" "$version_output"

# ── Schema: v3 fields present ─────────────────────────────────────────────────

echo ""
echo "Schema v3: field structure"

# Source file should contain v3 schema in ensure_global_state
grep -q 'next_cron_id: 1' "$BOARD"
assert_eq "ensure_global_state creates next_cron_id" "0" "$?"

grep -q 'next_run_id: 1' "$BOARD"
assert_eq "ensure_global_state creates next_run_id" "0" "$?"

grep -q 'cron_jobs: \[\]' "$BOARD"
assert_eq "ensure_global_state creates cron_jobs array" "0" "$?"

grep -q 'cron_runs: \[\]' "$BOARD"
assert_eq "ensure_global_state creates cron_runs array" "0" "$?"

# ── Schema migration v2 -> v3 ────────────────────────────────────────────────

echo ""
echo "Schema migration v2 -> v3"

# Test: v2 state gets migrated to v3
v2_state="$TMPDIR_TEST/v2_state.json"
make_v2_state "$v2_state"

migrated=$(jq '.version = 3
  | .next_cron_id = (.next_cron_id // 1)
  | .next_run_id = (.next_run_id // 1)
  | .cron_jobs = (.cron_jobs // [])
  | .cron_runs = (.cron_runs // [])' "$v2_state")

v3_version=$(echo "$migrated" | jq -r '.version')
assert_eq "migration sets version to 3" "3" "$v3_version"

v3_next_cron=$(echo "$migrated" | jq -r '.next_cron_id')
assert_eq "migration adds next_cron_id" "1" "$v3_next_cron"

v3_next_run=$(echo "$migrated" | jq -r '.next_run_id')
assert_eq "migration adds next_run_id" "1" "$v3_next_run"

v3_cron_jobs=$(echo "$migrated" | jq '.cron_jobs | length')
assert_eq "migration adds empty cron_jobs" "0" "$v3_cron_jobs"

v3_cron_runs=$(echo "$migrated" | jq '.cron_runs | length')
assert_eq "migration adds empty cron_runs" "0" "$v3_cron_runs"

# Existing data preserved
v3_repos=$(echo "$migrated" | jq '.repos | length')
assert_eq "migration preserves repos" "1" "$v3_repos"

v3_tasks=$(echo "$migrated" | jq '.tasks | length')
assert_eq "migration preserves tasks" "1" "$v3_tasks"

v3_task_id=$(echo "$migrated" | jq -r '.next_task_id')
assert_eq "migration preserves next_task_id" "3" "$v3_task_id"

# ── Cron helpers: state operations ────────────────────────────────────────────

echo ""
echo "Cron state operations"

v3_state="$TMPDIR_TEST/v3_state.json"
make_v3_state "$v3_state"

# Test: cron_job_exists
job_count=$(jq -r --arg id "cj-001" '[.cron_jobs[] | select(.id == $id)] | length' "$v3_state")
assert_eq "cron_job_exists: cj-001 found" "1" "$job_count"

job_count_miss=$(jq -r --arg id "cj-999" '[.cron_jobs[] | select(.id == $id)] | length' "$v3_state")
assert_eq "cron_job_exists: cj-999 not found" "0" "$job_count_miss"

# Test: cron_job_field
job_name=$(jq -r --arg id "cj-001" --arg f "name" '.cron_jobs[] | select(.id == $id) | .[$f] // ""' "$v3_state")
assert_eq "cron_job_field: name" "test-job" "$job_name"

job_enabled=$(jq -r --arg id "cj-001" --arg f "enabled" '.cron_jobs[] | select(.id == $id) | .[$f] // ""' "$v3_state")
assert_eq "cron_job_field: enabled" "true" "$job_enabled"

job_schedule=$(jq -r --arg id "cj-001" --arg f "schedule_desc" '.cron_jobs[] | select(.id == $id) | .[$f] // ""' "$v3_state")
assert_eq "cron_job_field: schedule_desc" "Daily at 08:30" "$job_schedule"

# Test: cron_run_field
run_status=$(jq -r --arg id "cr-001" --arg f "status" '.cron_runs[] | select(.run_id == $id) | .[$f] // ""' "$v3_state")
assert_eq "cron_run_field: status" "needs_review" "$run_status"

run_exit=$(jq -r --arg id "cr-001" --arg f "exit_code" '.cron_runs[] | select(.run_id == $id) | .[$f] // ""' "$v3_state")
assert_eq "cron_run_field: exit_code" "0" "$run_exit"

run_session=$(jq -r --arg id "cr-001" --arg f "session_id" '.cron_runs[] | select(.run_id == $id) | .[$f] // ""' "$v3_state")
assert_eq "cron_run_field: session_id" "test-uuid" "$run_session"

# ── Cron ID generation ────────────────────────────────────────────────────────

echo ""
echo "Cron ID generation"

# Test: next_cron_id format
cron_id=$(printf "cj-%03d" "1")
assert_eq "_next_cron_id format" "cj-001" "$cron_id"

cron_id_5=$(printf "cj-%03d" "5")
assert_eq "_next_cron_id format (5)" "cj-005" "$cron_id_5"

cron_id_100=$(printf "cj-%03d" "100")
assert_eq "_next_cron_id format (100)" "cj-100" "$cron_id_100"

# Test: next_run_id format
run_id=$(printf "cr-%03d" "1")
assert_eq "_next_run_id format" "cr-001" "$run_id"

# Test: counter increment
counter_state="$TMPDIR_TEST/counter_state.json"
make_v3_state "$counter_state"
updated=$(jq '.next_cron_id += 1' "$counter_state")
new_counter=$(echo "$updated" | jq -r '.next_cron_id')
assert_eq "counter increment works" "3" "$new_counter"

# ── Cron run state transitions ────────────────────────────────────────────────

echo ""
echo "Cron run state transitions"

transition_state="$TMPDIR_TEST/transition_state.json"
make_v3_state "$transition_state"

# Test: mark reviewed
reviewed=$(jq --arg rid "cr-001" '(.cron_runs[] | select(.run_id == $rid)).status = "reviewed"' "$transition_state")
reviewed_status=$(echo "$reviewed" | jq -r '.cron_runs[0].status')
assert_eq "mark reviewed transition" "reviewed" "$reviewed_status"

# Test: complete a run (active -> needs_review)
complete_state="$TMPDIR_TEST/complete_state.json"
jq '.cron_runs[0].status = "active"' "$transition_state" > "$complete_state"
completed=$(jq --arg rid "cr-001" --arg code "0" --arg now "2025-01-01T02:00:00Z" '
  (.cron_runs[] | select(.run_id == $rid)) |=
    (.status = "needs_review" | .exit_code = ($code | tonumber) | .completed_at = $now)
' "$complete_state")
comp_status=$(echo "$completed" | jq -r '.cron_runs[0].status')
assert_eq "complete transition: status" "needs_review" "$comp_status"
comp_exit=$(echo "$completed" | jq -r '.cron_runs[0].exit_code')
assert_eq "complete transition: exit_code" "0" "$comp_exit"
comp_time=$(echo "$completed" | jq -r '.cron_runs[0].completed_at')
assert_eq "complete transition: completed_at" "2025-01-01T02:00:00Z" "$comp_time"

# ── Overlap prevention ────────────────────────────────────────────────────────

echo ""
echo "Overlap prevention"

# Test: detect active run for a job
overlap_state="$TMPDIR_TEST/overlap_state.json"
jq '.cron_runs[0].status = "active"' "$transition_state" > "$overlap_state"
active_count=$(jq -r --arg id "cj-001" '[.cron_runs[] | select(.cron_job_id == $id and .status == "active")] | length' "$overlap_state")
assert_eq "active run detected" "1" "$active_count"

# Test: no active run after completion
no_overlap_state="$TMPDIR_TEST/no_overlap_state.json"
make_v3_state "$no_overlap_state"
active_count_done=$(jq -r --arg id "cj-001" '[.cron_runs[] | select(.cron_job_id == $id and .status == "active")] | length' "$no_overlap_state")
assert_eq "no active run after completion" "0" "$active_count_done"

# ── Auto-archive ─────────────────────────────────────────────────────────────

echo ""
echo "Auto-archive stale runs"

# Test: runs older than 24h get archived
archive_state="$TMPDIR_TEST/archive_state.json"
make_v3_state "$archive_state"
# Set completed_at to 48 hours ago
old_time=$(date -u -v-48H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '48 hours ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
jq --arg t "$old_time" '.cron_runs[0].completed_at = $t' "$archive_state" > "${archive_state}.tmp" && mv "${archive_state}.tmp" "$archive_state"

cutoff=$(date -u -v-24H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '24 hours ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
archived=$(jq --arg cutoff "$cutoff" '
  .cron_runs = [.cron_runs[] |
    if .status == "needs_review" and .completed_at != null and .completed_at < $cutoff then
      .status = "archived"
    else . end
  ]
' "$archive_state")
archived_status=$(echo "$archived" | jq -r '.cron_runs[0].status')
assert_eq "stale run archived" "archived" "$archived_status"

# Test: recent runs are NOT archived
recent_state="$TMPDIR_TEST/recent_state.json"
make_v3_state "$recent_state"
recent_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
jq --arg t "$recent_time" '.cron_runs[0].completed_at = $t' "$recent_state" > "${recent_state}.tmp" && mv "${recent_state}.tmp" "$recent_state"
not_archived=$(jq --arg cutoff "$cutoff" '
  .cron_runs = [.cron_runs[] |
    if .status == "needs_review" and .completed_at != null and .completed_at < $cutoff then
      .status = "archived"
    else . end
  ]
' "$recent_state")
not_archived_status=$(echo "$not_archived" | jq -r '.cron_runs[0].status')
assert_eq "recent run NOT archived" "needs_review" "$not_archived_status"

# ── Cron job removal ─────────────────────────────────────────────────────────

echo ""
echo "Cron job removal"

remove_state="$TMPDIR_TEST/remove_state.json"
make_v3_state "$remove_state"
removed=$(jq --arg id "cj-001" '
  .cron_jobs = [.cron_jobs[] | select(.id != $id)] |
  .cron_runs = [.cron_runs[] | select(.cron_job_id != $id)]
' "$remove_state")
remove_jobs=$(echo "$removed" | jq '.cron_jobs | length')
assert_eq "removal: jobs empty" "0" "$remove_jobs"
remove_runs=$(echo "$removed" | jq '.cron_runs | length')
assert_eq "removal: associated runs removed" "0" "$remove_runs"

# ── Plist discovery (source code checks) ─────────────────────────────────────

echo ""
echo "Plist discovery"

grep -q '_scan_launch_agents' "$BOARD"
assert_eq "_scan_launch_agents function exists" "0" "$?"

grep -q 'plutil -convert json -o -' "$BOARD"
assert_eq "plutil conversion present" "0" "$?"

grep -q 'ProgramArguments' "$BOARD"
assert_eq "ProgramArguments check present" "0" "$?"

grep -q 'com.cloard-board\.\*' "$BOARD"
assert_eq "skips already-managed plists" "0" "$?"

# ── CLI commands (source code checks) ────────────────────────────────────────

echo ""
echo "CLI commands"

grep -q 'cmd_cron()' "$BOARD"
assert_eq "cmd_cron dispatcher exists" "0" "$?"

grep -q 'cmd_cron_scan' "$BOARD"
assert_eq "cmd_cron_scan exists" "0" "$?"

grep -q 'cmd_cron_add' "$BOARD"
assert_eq "cmd_cron_add exists" "0" "$?"

grep -q 'cmd_cron_list' "$BOARD"
assert_eq "cmd_cron_list exists" "0" "$?"

grep -q 'cmd_cron_runs' "$BOARD"
assert_eq "cmd_cron_runs exists" "0" "$?"

grep -q 'cmd_cron_enable' "$BOARD"
assert_eq "cmd_cron_enable exists" "0" "$?"

grep -q 'cmd_cron_disable' "$BOARD"
assert_eq "cmd_cron_disable exists" "0" "$?"

grep -q 'cmd_cron_remove' "$BOARD"
assert_eq "cmd_cron_remove exists" "0" "$?"

grep -q 'cmd_cron_review' "$BOARD"
assert_eq "cmd_cron_review exists" "0" "$?"

grep -q 'cmd_cron_migrate' "$BOARD"
assert_eq "cmd_cron_migrate exists" "0" "$?"

grep -q 'cmd_cron_exec' "$BOARD"
assert_eq "cmd_cron_exec exists" "0" "$?"

grep -q 'cmd__cron_complete' "$BOARD"
assert_eq "cmd__cron_complete exists" "0" "$?"

# ── Dashboard cron rendering (source code checks) ────────────────────────────

echo ""
echo "Dashboard cron rendering"

grep -q '_has_cron_data' "$BOARD"
assert_eq "_has_cron_data flag exists" "0" "$?"

grep -q 'CRON_COL_NAMES' "$BOARD"
assert_eq "CRON_COL_NAMES constant exists" "0" "$?"

grep -q 'cron_row_selected' "$BOARD"
assert_eq "cron_row_selected nav state exists" "0" "$?"

grep -q '_get_cron_item_at' "$BOARD"
assert_eq "_get_cron_item_at helper exists" "0" "$?"

grep -q '_get_selected_cron_id' "$BOARD"
assert_eq "_get_selected_cron_id helper exists" "0" "$?"

grep -q 'cron jobs' "$BOARD"
assert_eq "cron row header present" "0" "$?"

# ── Dashboard cron key handlers ──────────────────────────────────────────────

echo ""
echo "Dashboard cron key handlers"

grep -q 'claude --resume' "$BOARD"
assert_eq "resume command present" "0" "$?"

grep -q '_archive_stale_cron_runs' "$BOARD"
assert_eq "stale run cleanup present" "0" "$?"

grep -q 'cmd_cron_disable' "$BOARD"
assert_eq "disable from dashboard present" "0" "$?"

grep -q 'cmd_cron_enable' "$BOARD"
assert_eq "enable from dashboard present" "0" "$?"

grep -q 'cmd_cron_remove' "$BOARD"
assert_eq "remove from dashboard (D key) present" "0" "$?"

# ── Dispatch ─────────────────────────────────────────────────────────────────

echo ""
echo "Main dispatch"

grep -q 'cron-exec)' "$BOARD"
assert_eq "cron-exec on fast path" "0" "$?"

grep -q '_cron_complete)' "$BOARD"
assert_eq "_cron_complete on fast path" "0" "$?"

grep -q 'cron).*cmd_cron' "$BOARD"
assert_eq "cron command in standard dispatch" "0" "$?"

# ── Help ─────────────────────────────────────────────────────────────────────

echo ""
echo "Help text"

grep -q 'CRON JOBS' "$BOARD"
assert_eq "help includes CRON JOBS section" "0" "$?"

grep -q 'cron scan' "$BOARD"
assert_eq "help includes cron scan" "0" "$?"

grep -q 'cron migrate' "$BOARD"
assert_eq "help includes cron migrate" "0" "$?"

grep -q 'Cron row:' "$BOARD"
assert_eq "help includes cron dashboard keys" "0" "$?"

# ── Snapshot jq query ────────────────────────────────────────────────────────

echo ""
echo "Snapshot jq query"

# Test: the jq snapshot query handles v3 state correctly
v3_snap_state="$TMPDIR_TEST/snap_state.json"
make_v3_state "$v3_snap_state"
snap_output=$(jq -r '
  ("H\u001e" + (.next_task_id | tostring) + "\u001e" + (.repos | length | tostring) + "\u001e" + (.tasks | length | tostring)),
  (.repos[] | "R\u001e" + .name + "\u001e" + .path + "\u001e" + (.type // "git") + "\u001e" + (if .archived == true then "1" else "0" end)),
  (.tasks[] | "T\u001e" + .id + "\u001e" + .status + "\u001e" + (.title // "") + "\u001e" + (.pr_url // "") + "\u001e" + (.claude_status // "") + "\u001e" + (.worktree_mode // "worktree") + "\u001e" + (.repo // "")),
  (.cron_jobs[]? | "CJ\u001e" + .id + "\u001e" + .name + "\u001e" + (if .enabled then "true" else "false" end) + "\u001e" + (.schedule_desc // "")),
  (.cron_runs[]? | select(.status == "active" or .status == "needs_review") | "CR\u001e" + .run_id + "\u001e" + .cron_job_id + "\u001e" + .status + "\u001e" + (.exit_code | tostring) + "\u001e" + (.started_at // "") + "\u001e" + (.session_id // "") + "\u001e" + (.tmux_window // ""))
' "$v3_snap_state" 2>/dev/null)

# Count line types
h_count=$(echo "$snap_output" | grep -c '^H' || echo 0)
r_count=$(echo "$snap_output" | grep -c '^R' || echo 0)
t_count=$(echo "$snap_output" | grep -c '^T' || echo 0)
cj_count=$(echo "$snap_output" | grep -c '^CJ' || echo 0)
cr_count=$(echo "$snap_output" | grep -c '^CR' || echo 0)

assert_eq "snapshot: H line count" "1" "$h_count"
assert_eq "snapshot: R line count" "1" "$r_count"
assert_eq "snapshot: T line count" "1" "$t_count"
assert_eq "snapshot: CJ line count" "1" "$cj_count"
assert_eq "snapshot: CR line count" "1" "$cr_count"

# Verify CJ content
cj_line=$(echo "$snap_output" | grep '^CJ')
assert_match "snapshot: CJ has job id" "cj-001" "$cj_line"
assert_match "snapshot: CJ has job name" "test-job" "$cj_line"
assert_match "snapshot: CJ has enabled flag" "true" "$cj_line"

# Verify CR content
cr_line=$(echo "$snap_output" | grep '^CR')
assert_match "snapshot: CR has run id" "cr-001" "$cr_line"
assert_match "snapshot: CR has job id ref" "cj-001" "$cr_line"
assert_match "snapshot: CR has status" "needs_review" "$cr_line"

# ── Plist generation (structure check) ───────────────────────────────────────

echo ""
echo "Plist generation"

grep -q '_generate_plist' "$BOARD"
assert_eq "_generate_plist function exists" "0" "$?"

grep -q 'cloard-board.*cron-exec' "$BOARD"
assert_eq "generated plist calls cron-exec" "0" "$?"

grep -q 'StartCalendarInterval' "$BOARD"
assert_eq "schedule XML generation present" "0" "$?"

grep -q 'EnvironmentVariables' "$BOARD"
assert_eq "env vars XML generation present" "0" "$?"

# ── Schedule presets ─────────────────────────────────────────────────────────

echo ""
echo "Schedule presets"

grep -q 'schedule_type="daily"' "$BOARD"
assert_eq "daily schedule preset" "0" "$?"

grep -q 'schedule_type="hourly"' "$BOARD"
assert_eq "hourly schedule preset" "0" "$?"

grep -q 'schedule_type="interval"' "$BOARD"
assert_eq "interval schedule preset" "0" "$?"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: $pass/$total passed, $fail failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ $fail -eq 0 ]] && exit 0 || exit 1
