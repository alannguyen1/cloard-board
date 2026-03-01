#!/usr/bin/env zsh
# Tests for cloard-board list mode:
#   A: Source structure (new modules present)
#   B: List snapshot sorting (_list_build_items)
#   C: List render functions present
#   D: Split-pane lifecycle functions present
#   E: Key dispatch and context transfer
#   F: Scrollbar math
#   G: Footer and help updates
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

# Helper: run a zsh snippet from a temp file (passes $BOARD as $1)
run_zsh() {
  local script="$TMPDIR_TEST/test_$$.zsh"
  cat > "$script"
  zsh "$script" "$BOARD" "$BOARD_SRC" 2>/dev/null
}

# Extract functions from built script, stripping main() dispatch to allow sourcing
# This creates a sourceable version that won't auto-execute
BOARD_SRC="$TMPDIR_TEST/board_src.zsh"
sed '/^main "\$@"$/d' "$BOARD" > "$BOARD_SRC"

# ── A: Source structure ───────────────────────────────────────────────────────

echo ""
echo "A: New source modules present in built script"

grep -q '_list_build_items' "$BOARD"
assert_eq "_list_build_items function present" "0" "$?"

grep -q '_render_list_full' "$BOARD"
assert_eq "_render_list_full function present" "0" "$?"

grep -q '_render_list_sidebar' "$BOARD"
assert_eq "_render_list_sidebar function present" "0" "$?"

grep -q '_render_list_group_header' "$BOARD"
assert_eq "_render_list_group_header function present" "0" "$?"

grep -q '_render_list_task_card' "$BOARD"
assert_eq "_render_list_task_card function present" "0" "$?"

grep -q '_render_list_cron_card' "$BOARD"
assert_eq "_render_list_cron_card function present" "0" "$?"

grep -q '_render_scrollbar_track' "$BOARD"
assert_eq "_render_scrollbar_track function present" "0" "$?"

grep -q '_list_handle_key' "$BOARD"
assert_eq "_list_handle_key function present" "0" "$?"

grep -q '_list_get_selected_id' "$BOARD"
assert_eq "_list_get_selected_id function present" "0" "$?"

grep -q '_list_adjust_scroll' "$BOARD"
assert_eq "_list_adjust_scroll function present" "0" "$?"

grep -q '_list_item_height' "$BOARD"
assert_eq "_list_item_height function present" "0" "$?"

grep -q '_list_content_line_of' "$BOARD"
assert_eq "_list_content_line_of function present" "0" "$?"

# ── B: List snapshot sorting ─────────────────────────────────────────────────

echo ""
echo "B: _list_build_items sorting logic"

# Test: sorting produces correct priority order
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

# Mock snapshot data
typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo
typeset -A _repo_cols _repo_col_cnt _repo_task_count _repo_stale
typeset -A _cron_col_ids _cron_col_cnt _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _list_group_collapsed
local -a _repo_names _list_items
local _show_done=0 _list_cursor=0 _list_follow_id="" _has_cron_data=false
local _total_task_count=0 _active_count=0 _review_count=0

# Set up one repo with tasks in various states
_repo_names=("test-repo")
_repo_task_count[test-repo]=5
_repo_cols[test-repo:0]="t-003 t-005"   # pending col: t-003=pending, t-005=paused
_repo_cols[test-repo:1]="t-001 t-002"   # active col
_repo_cols[test-repo:2]="t-004"         # needs_review col
_repo_cols[test-repo:3]=""              # done col
_repo_col_cnt[test-repo:0]=2
_repo_col_cnt[test-repo:1]=2
_repo_col_cnt[test-repo:2]=1
_repo_col_cnt[test-repo:3]=0

_task_status[t-001]="active"
_task_claude[t-001]="working"
_task_status[t-002]="active"
_task_claude[t-002]=""
_task_status[t-003]="pending"
_task_claude[t-003]=""
_task_status[t-004]="needs_review"
_task_claude[t-004]=""
_task_status[t-005]="paused"
_task_claude[t-005]=""

for _ci in {0..3}; do
  _cron_col_ids[__cron:${_ci}]=""
  _cron_col_cnt[__cron:${_ci}]=0
done

_list_build_items

# Output items in order
for item in "${_list_items[@]}"; do
  echo "$item"
done
SCRIPT
)

# Expected order: group:test-repo, task:t-001 (active+working=0), task:t-002 (active=2),
#                 task:t-004 (needs_review=3), task:t-003 (pending=4), task:t-005 (paused=5),
#                 cron_group:__cron
expected=$(cat <<'EOF'
group:test-repo
task:t-001
task:t-002
task:t-004
task:t-003
task:t-005
cron_group:__cron
EOF
)
assert_eq "sorting: active+working first" "$expected" "$result"

# Test: done tasks hidden when _show_done=0
result2=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo
typeset -A _repo_cols _repo_col_cnt _repo_task_count _repo_stale
typeset -A _cron_col_ids _cron_col_cnt _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _list_group_collapsed
local -a _repo_names _list_items
local _show_done=0 _list_cursor=0 _list_follow_id="" _has_cron_data=false
local _total_task_count=0 _active_count=0 _review_count=0

_repo_names=("r1")
_repo_task_count[r1]=2
_repo_cols[r1:0]="t-001"
_repo_cols[r1:1]=""
_repo_cols[r1:2]=""
_repo_cols[r1:3]="t-002"
_repo_col_cnt[r1:0]=1
_repo_col_cnt[r1:1]=0
_repo_col_cnt[r1:2]=0
_repo_col_cnt[r1:3]=1

_task_status[t-001]="pending"
_task_claude[t-001]=""
_task_status[t-002]="done"
_task_claude[t-002]=""

for _ci in {0..3}; do
  _cron_col_ids[__cron:${_ci}]=""
  _cron_col_cnt[__cron:${_ci}]=0
done

_list_build_items

local found_done=0
for item in "${_list_items[@]}"; do
  [[ "$item" == "task:t-002" ]] && found_done=1
done
echo "$found_done"
SCRIPT
)
assert_eq "done tasks hidden when _show_done=0" "0" "$result2"

# Test: done tasks visible when _show_done=1
result3=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo
typeset -A _repo_cols _repo_col_cnt _repo_task_count _repo_stale
typeset -A _cron_col_ids _cron_col_cnt _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _list_group_collapsed
local -a _repo_names _list_items
local _show_done=1 _list_cursor=0 _list_follow_id="" _has_cron_data=false
local _total_task_count=0 _active_count=0 _review_count=0

_repo_names=("r1")
_repo_task_count[r1]=2
_repo_cols[r1:0]="t-001"
_repo_cols[r1:1]=""
_repo_cols[r1:2]=""
_repo_cols[r1:3]="t-002"
_repo_col_cnt[r1:0]=1
_repo_col_cnt[r1:1]=0
_repo_col_cnt[r1:2]=0
_repo_col_cnt[r1:3]=1

_task_status[t-001]="pending"
_task_claude[t-001]=""
_task_status[t-002]="done"
_task_claude[t-002]=""

for _ci in {0..3}; do
  _cron_col_ids[__cron:${_ci}]=""
  _cron_col_cnt[__cron:${_ci}]=0
done

_list_build_items

local found_done=0
for item in "${_list_items[@]}"; do
  [[ "$item" == "task:t-002" ]] && found_done=1
done
echo "$found_done"
SCRIPT
)
assert_eq "done tasks visible when _show_done=1" "1" "$result3"

# Test: collapsed group hides tasks
result4=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo
typeset -A _repo_cols _repo_col_cnt _repo_task_count _repo_stale
typeset -A _cron_col_ids _cron_col_cnt _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _list_group_collapsed
local -a _repo_names _list_items
local _show_done=0 _list_cursor=0 _list_follow_id="" _has_cron_data=false
local _total_task_count=0 _active_count=0 _review_count=0

_repo_names=("myrepo")
_repo_task_count[myrepo]=1
_repo_cols[myrepo:0]="t-001"
_repo_cols[myrepo:1]=""
_repo_cols[myrepo:2]=""
_repo_cols[myrepo:3]=""
_repo_col_cnt[myrepo:0]=1
_repo_col_cnt[myrepo:1]=0
_repo_col_cnt[myrepo:2]=0
_repo_col_cnt[myrepo:3]=0

_task_status[t-001]="pending"
_task_claude[t-001]=""

_list_group_collapsed[myrepo]=1

for _ci in {0..3}; do
  _cron_col_ids[__cron:${_ci}]=""
  _cron_col_cnt[__cron:${_ci}]=0
done

_list_build_items
echo "${#_list_items[@]}"
SCRIPT
)
assert_eq "collapsed group hides tasks (only group + cron header)" "2" "$result4"

# Test: _list_follow_id repositions cursor
result5=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo
typeset -A _repo_cols _repo_col_cnt _repo_task_count _repo_stale
typeset -A _cron_col_ids _cron_col_cnt _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _list_group_collapsed
local -a _repo_names _list_items
local _show_done=0 _list_cursor=0 _list_follow_id="t-003" _has_cron_data=false
local _total_task_count=0 _active_count=0 _review_count=0

_repo_names=("r1")
_repo_task_count[r1]=3
_repo_cols[r1:0]="t-002 t-003"
_repo_cols[r1:1]="t-001"
_repo_cols[r1:2]=""
_repo_cols[r1:3]=""
_repo_col_cnt[r1:0]=2
_repo_col_cnt[r1:1]=1
_repo_col_cnt[r1:2]=0
_repo_col_cnt[r1:3]=0

_task_status[t-001]="active"
_task_claude[t-001]=""
_task_status[t-002]="pending"
_task_claude[t-002]=""
_task_status[t-003]="pending"
_task_claude[t-003]=""

for _ci in {0..3}; do
  _cron_col_ids[__cron:${_ci}]=""
  _cron_col_cnt[__cron:${_ci}]=0
done

_list_build_items
echo "$_list_cursor"
SCRIPT
)
assert_eq "follow_id repositions cursor to t-003" "3" "$result5"

# ── C: List render functions ─────────────────────────────────────────────────

echo ""
echo "C: List render functions structure"

# Item height logic
grep -q "group:\*|cron_group:\*) _lih=1" "$BOARD"
assert_eq "group items have height 1" "0" "$?"

grep -q "task:\*|cron:\*.*_lih=2" "$BOARD"
assert_eq "task items have height 2" "0" "$?"

# Group header uses expand/collapse arrows
grep -q '▼' "$BOARD"
assert_eq "expanded arrow ▼ present" "0" "$?"

grep -q '▶' "$BOARD"
assert_eq "collapsed arrow ▶ present" "0" "$?"

# Task card status badges
grep -q '● Active' "$BOARD"
assert_eq "active badge present" "0" "$?"

grep -q '◆ Review' "$BOARD"
assert_eq "review badge present" "0" "$?"

grep -q '○ Pending' "$BOARD"
assert_eq "pending badge present" "0" "$?"

grep -q '◫ Paused' "$BOARD"
assert_eq "paused badge present" "0" "$?"

grep -q '✓ Done' "$BOARD"
assert_eq "done badge present" "0" "$?"

# ── D: Split-pane lifecycle ─────────────────────────────────────────────────

echo ""
echo "D: Split-pane lifecycle functions"

grep -q '_split_open' "$BOARD"
assert_eq "_split_open function present" "0" "$?"

grep -q '_split_switch_session' "$BOARD"
assert_eq "_split_switch_session function present" "0" "$?"

grep -q '_split_close' "$BOARD"
assert_eq "_split_close function present" "0" "$?"

grep -q '_split_build_cmd' "$BOARD"
assert_eq "_split_build_cmd helper present" "0" "$?"

grep -q 'join-pane.*-h.*-s.*board:' "$BOARD"
assert_eq "join-pane for existing windows" "0" "$?"

grep -q 'break-pane.*-d.*-s.*board:dashboard.1' "$BOARD"
assert_eq "break-pane preserves sessions" "0" "$?"

grep -q 'split-window.*-h.*-t.*board:dashboard.*-p 60' "$BOARD"
assert_eq "split-window with 60% right pane" "0" "$?"

grep -q 'select-pane.*-t.*board:dashboard.0' "$BOARD"
assert_eq "select-pane returns to dashboard" "0" "$?"

# ── E: Key dispatch and context transfer ─────────────────────────────────────

echo ""
echo "E: Key dispatch and context transfer"

# View mode state
grep -q '_view_mode="kanban"' "$BOARD"
assert_eq "_view_mode state variable present" "0" "$?"

# v key toggles view
grep -q 'v).*Toggle kanban/list' "$BOARD"
assert_eq "v key handler present" "0" "$?"

grep -q '_list_transfer_from_kanban' "$BOARD"
assert_eq "_list_transfer_from_kanban function present" "0" "$?"

grep -q '_list_transfer_to_kanban' "$BOARD"
assert_eq "_list_transfer_to_kanban function present" "0" "$?"

# _get_active_task_id helper
grep -q '_get_active_task_id' "$BOARD"
assert_eq "_get_active_task_id helper present" "0" "$?"

# Shared keys use _get_active_task_id
grep -q '_get_active_task_id' "$BOARD"
assert_eq "shared keys use _get_active_task_id" "0" "$?"

# List mode dispatch
grep -q '_list_handle_key' "$BOARD"
assert_eq "list mode key dispatch present" "0" "$?"

# List mode rendering branch
grep -q '_view_mode.*==.*list' "$BOARD"
assert_eq "list mode rendering branch present" "0" "$?"

# b key for split toggle
grep -q 'b).*Toggle split view' "$BOARD"
assert_eq "b key handler for split toggle" "0" "$?"

# D key for done toggle in list mode
grep -q 'D).*Toggle show done' "$BOARD"
assert_eq "D key handler for done toggle" "0" "$?"

# Tab jumps between groups
grep -q 'Tab.*jump.*cursor.*to.*next.*group' "$BOARD"
assert_eq "Tab jumps between groups" "0" "$?"

# Context transfer sets correct kanban state
grep -q 'cur_repo_idx=\$ri' "$BOARD"
assert_eq "context transfer sets cur_repo_idx" "0" "$?"

# ── F: Scrollbar math ───────────────────────────────────────────────────────

echo ""
echo "F: Scrollbar math"

# Scrollbar track character
grep -q '│' "$BOARD"
assert_eq "scrollbar track character present" "0" "$?"

# Scrollbar thumb character
grep -q '█' "$BOARD"
assert_eq "scrollbar thumb character present" "0" "$?"

# Scrollbar calculations
grep -q 'thumb_size' "$BOARD"
assert_eq "thumb_size calculation present" "0" "$?"

grep -q 'thumb_pos' "$BOARD"
assert_eq "thumb_pos calculation present" "0" "$?"

# Scrollbar only renders when content exceeds viewport
grep -q 'total_content_lines.*-le.*viewport_height.*return' "$BOARD"
assert_eq "scrollbar skipped when content fits" "0" "$?"

# Scrollbar uses move_to for positioning
grep -q 'move_to.*_ri.*2.*cols' "$BOARD"
assert_eq "scrollbar uses move_to for positioning" "0" "$?"

# ── G: Footer and help updates ──────────────────────────────────────────────

echo ""
echo "G: Footer and help text updates"

# Footer shows list-mode hints
grep -q 'v: kanban' "$BOARD"
assert_eq "footer shows v: kanban hint" "0" "$?"

grep -q 'v: list' "$BOARD"
assert_eq "footer shows v: list hint (kanban mode)" "0" "$?"

grep -q 'b: split' "$BOARD"
assert_eq "footer shows b: split hint" "0" "$?"

grep -q 'b: full list' "$BOARD"
assert_eq "footer shows b: full list hint (split mode)" "0" "$?"

# Help text has list view section
grep -q 'List view:' "$BOARD"
assert_eq "help has List view section" "0" "$?"

grep -q 'Toggle between kanban and list view' "$BOARD"
assert_eq "help describes v key for view toggle" "0" "$?"

grep -q 'Toggle split view' "$BOARD"
assert_eq "help describes split view toggle" "0" "$?"

# Main dispatcher has _split_session
grep -q '_split_session' "$BOARD"
assert_eq "_split_session in main dispatcher" "0" "$?"

# ── H: Cron in list mode ────────────────────────────────────────────────────

echo ""
echo "H: Cron integration in list mode"

# Cron group header
grep -q 'cron_group:__cron' "$BOARD"
assert_eq "cron_group:__cron in list items" "0" "$?"

# Cron items sorted by column priority (active > needs_review > scheduled)
result_cron=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo
typeset -A _repo_cols _repo_col_cnt _repo_task_count _repo_stale
typeset -A _cron_col_ids _cron_col_cnt _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _list_group_collapsed
local -a _repo_names _list_items
local _show_done=0 _list_cursor=0 _list_follow_id="" _has_cron_data=true
local _total_task_count=0 _active_count=0 _review_count=0

_repo_names=()
for _ci in {0..3}; do
  _cron_col_ids[__cron:${_ci}]=""
  _cron_col_cnt[__cron:${_ci}]=0
done

_cron_col_ids[__cron:0]="cj-001"
_cron_col_cnt[__cron:0]=1
_cron_col_ids[__cron:1]="cr-001"
_cron_col_cnt[__cron:1]=1
_cron_col_ids[__cron:2]="cr-002"
_cron_col_cnt[__cron:2]=1

_cron_jobs[cj-001]="daily-backup"

_list_build_items

for item in "${_list_items[@]}"; do
  echo "$item"
done
SCRIPT
)

expected_cron=$(cat <<'EOF'
cron_group:__cron
cron:cr-001
cron:cr-002
cron:cj-001
EOF
)
assert_eq "cron items: active first, then review, then scheduled" "$expected_cron" "$result_cron"

# Cron row only in kanban mode
grep -q '_view_mode.*==.*kanban.*&&.*_has_cron_data' "$BOARD"
assert_eq "cron row only renders in kanban mode" "0" "$?"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: ${pass}/${total} passed, ${fail} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ $fail -eq 0 ]] || exit 1
