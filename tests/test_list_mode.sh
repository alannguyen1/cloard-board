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
typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
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

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
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

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
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

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
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

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
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

grep -q "task:\*|cron:\*.*_lih=1" "$BOARD"
assert_eq "task items have height 1" "0" "$?"

# Group header and status badges use centralized ASCII-safe glyphs
grep -Fq 'readonly TUI_GLYPH_EXPANDED="v"' "$BOARD"
assert_eq "expanded group glyph uses ASCII-safe palette" "0" "$?"

grep -Fq 'readonly TUI_GLYPH_COLLAPSED=">"' "$BOARD"
assert_eq "collapsed group glyph uses ASCII-safe palette" "0" "$?"

grep -Fq 'readonly TUI_GLYPH_ACTIVE="*"' "$BOARD"
assert_eq "active badge glyph uses ASCII-safe palette" "0" "$?"

grep -Fq 'readonly TUI_GLYPH_REVIEW="!"' "$BOARD"
assert_eq "review badge glyph uses ASCII-safe palette" "0" "$?"

grep -Fq 'readonly TUI_GLYPH_PENDING="o"' "$BOARD"
assert_eq "pending badge glyph uses ASCII-safe palette" "0" "$?"

grep -Fq 'readonly TUI_GLYPH_PAUSED="="' "$BOARD"
assert_eq "paused badge glyph uses ASCII-safe palette" "0" "$?"

grep -Fq 'readonly TUI_GLYPH_DONE="x"' "$BOARD"
assert_eq "done badge glyph uses ASCII-safe palette" "0" "$?"

grep -Fq 'readonly TUI_ELLIPSIS="..."' "$BOARD"
assert_eq "ellipsis uses ASCII-safe palette" "0" "$?"

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

grep -q "join-pane.*-l '60%'" "$BOARD"
assert_eq "join-pane uses -l percentage (not -p)" "0" "$?"

grep -q 'break-pane.*-d.*-s.*board:dashboard.1' "$BOARD"
assert_eq "break-pane preserves sessions" "0" "$?"

grep -q 'split-window.*-h.*-t.*board:dashboard.*-p 60' "$BOARD"
assert_eq "split-window with 60% right pane" "0" "$?"

grep -q 'select-pane.*-t.*board:dashboard.1' "$BOARD"
assert_eq "select-pane focuses Claude pane" "0" "$?"

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

# d key for show/hide done tasks (shared handler, not in _list_handle_key)
grep -q '_show_done' "$BOARD"
assert_eq "d key show done toggle variable present" "0" "$?"

# D key for cron delete in list mode
grep -q 'D).*Delete scheduled cron' "$BOARD"
assert_eq "D key handler for cron delete" "0" "$?"

# Tab cycles repo filter
grep -q 'Tab.*cycle.*repo.*filter' "$BOARD"
assert_eq "Tab cycles repo filter" "0" "$?"

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

grep -q 'b: dock' "$BOARD"
assert_eq "footer shows b: dock hint" "0" "$?"

grep -q 'b: undock' "$BOARD"
assert_eq "footer shows b: undock hint (split mode)" "0" "$?"

# Help text has list view section
grep -q 'List view:' "$BOARD"
assert_eq "help has List view section" "0" "$?"

grep -q 'Switch back to kanban view when no dock is active' "$BOARD"
assert_eq "help describes v key dock guard" "0" "$?"

grep -q 'Toggle the sidebar dock on/off' "$BOARD"
assert_eq "help describes sidebar dock toggle" "0" "$?"

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

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
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

# ── I: Split pane UX improvements ──────────────────────────────────────────

echo ""
echo "I: Split pane UX improvements"

# F key handler in _list_handle_key
grep -q 'F).*Full-screen the Claude session' "$BOARD"
assert_eq "F key handler present in list mode" "0" "$?"

# F key calls _split_close then tmux_select_window
result_F=$(sed -n '/F).*Full-screen/,/;;/p' "$BOARD")
echo "$result_F" | grep -q '_split_close'
assert_eq "F key calls _split_close" "0" "$?"
echo "$result_F" | grep -q 'tmux_select_window'
assert_eq "F key calls tmux_select_window" "0" "$?"

# F key in list-mode dispatch table
grep -qE 'j\|k\|.*\|F\|' "$BOARD"
assert_eq "F key in list mode dispatch table" "0" "$?"

# Ctrl-F binding (changed from Ctrl-S to avoid Claude Code clash)
grep -q 'C-f.*if-shell.*last-pane' "$BOARD"
assert_eq "Ctrl-F binding with if-shell guard" "0" "$?"

# Ctrl-F unbind
grep -q 'unbind-key.*C-f' "$BOARD"
assert_eq "Ctrl-F unbind present" "0" "$?"

# No Ctrl-S tmux bindings remain (replaced by Ctrl-F)
result_cs=$(grep -c 'bind.*C-s\|unbind.*C-s' "$BOARD" || true)
assert_eq "no C-s bindings remain" "0" "$result_cs"

# _split_initial_prompt support in _split_build_cmd
grep -q '_split_initial_prompt' "$BOARD"
assert_eq "_split_initial_prompt support in _split_build_cmd" "0" "$?"

# c key in list mode routes through split pane
grep -qE '_view_mode.*==.*list.*_split_initial_prompt' "$BOARD" || \
  result_c=$(sed -n '/new_id.*then/,/fi.*fi/p' "$BOARD" | grep -c '_split_initial_prompt')
assert_eq "c key routes through split pane in list mode" "1" "$(( result_c >= 1 ? 1 : 0 ))"

# Default view mode is list
grep -q '_view_mode="list"' "$BOARD"
assert_eq "default view mode is list" "0" "$?"

# Footer shows F: fullscreen in split mode
grep -q 'F: fullscreen' "$BOARD"
assert_eq "footer shows F: fullscreen" "0" "$?"

# Footer shows Ctrl-F: toggle in split mode
grep -q 'Ctrl-F: toggle' "$BOARD"
assert_eq "footer shows Ctrl-F: toggle" "0" "$?"

# Help text has F key entry
grep -q 'F.*Full-screen the Claude session' "$BOARD"
assert_eq "help text has F key entry" "0" "$?"

# Help text has Ctrl-F entry
grep -q 'Ctrl-F.*Toggle focus' "$BOARD"
assert_eq "help text has Ctrl-F entry" "0" "$?"

# ── J: Stale window cleanup ────────────────────────────────────────────────

echo ""
echo "J: Stale window cleanup"

# _purge_stale_windows function present
grep -q '_purge_stale_windows()' "$BOARD"
assert_eq "_purge_stale_windows function present" "0" "$?"

# _purge_stale_windows has iteration limit (prevents infinite loop)
grep -q '_pw_i -lt 50' "$BOARD"
assert_eq "_purge_stale_windows has iteration limit" "0" "$?"

# _split_open calls _purge_stale_windows
result_open=$(sed -n '/_split_open()/,/^}/p' "$BOARD" | grep '_purge_stale_windows')
assert_match "_split_open purges stale windows" '_purge_stale_windows' "$result_open"

# _split_switch_session calls _purge_stale_windows for old and new task (swap + fallback paths)
result_switch=$(sed -n '/_split_switch_session()/,/^}/p' "$BOARD" | grep -c '_purge_stale_windows')
assert_eq "_split_switch_session purges both old and new task" "4" "$result_switch"

# _split_close calls _purge_stale_windows
result_close=$(sed -n '/_split_close()/,/^}/p' "$BOARD" | grep '_purge_stale_windows')
assert_match "_split_close purges stale windows" '_purge_stale_windows' "$result_close"

# ── K: Reviewed cron runs hidden with d toggle ─────────────────────────────

echo ""
echo "K: Reviewed cron runs hidden with d toggle"

# Test: reviewed cron runs hidden when _show_done=0
result_cron_hidden=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_cols _repo_col_cnt _repo_task_count _repo_stale
typeset -A _cron_col_ids _cron_col_cnt _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _list_group_collapsed
local -a _repo_names _list_items
local _show_done=0 _list_cursor=0 _list_follow_id="" _has_cron_data=true
local _total_task_count=0 _active_count=0 _review_count=0

_repo_names=("test-repo")
_repo_task_count[test-repo]=0
for _ci in {0..3}; do _repo_cols[test-repo:${_ci}]=""; _repo_col_cnt[test-repo:${_ci}]=0; done

# Cron: one active, one needs_review, one reviewed, one scheduled
_cron_col_ids[__cron:0]="cj-001"
_cron_col_ids[__cron:1]="cr-001"
_cron_col_ids[__cron:2]="cr-002"
_cron_col_ids[__cron:3]="cr-003"
_cron_col_cnt[__cron:0]=1
_cron_col_cnt[__cron:1]=1
_cron_col_cnt[__cron:2]=1
_cron_col_cnt[__cron:3]=1

_list_build_items
echo "${#_list_items[@]}"
for item in "${_list_items[@]}"; do echo "$item"; done
SCRIPT
)
# With _show_done=0: reviewed (col 3) should be hidden
# Expected items: group:test-repo, cron_group:__cron, cron:cr-001 (active), cron:cr-002 (needs_review), cron:cj-001 (scheduled)
item_count=$(echo "$result_cron_hidden" | head -1)
assert_eq "reviewed cron runs hidden when _show_done=0 (count=5)" "5" "$item_count"
echo "$result_cron_hidden" | grep -qv 'cron:cr-003'
assert_eq "cr-003 (reviewed) not in list" "0" "$?"

# Test: reviewed cron runs visible when _show_done=1
result_cron_shown=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_cols _repo_col_cnt _repo_task_count _repo_stale
typeset -A _cron_col_ids _cron_col_cnt _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _list_group_collapsed
local -a _repo_names _list_items
local _show_done=1 _list_cursor=0 _list_follow_id="" _has_cron_data=true
local _total_task_count=0 _active_count=0 _review_count=0

_repo_names=("test-repo")
_repo_task_count[test-repo]=0
for _ci in {0..3}; do _repo_cols[test-repo:${_ci}]=""; _repo_col_cnt[test-repo:${_ci}]=0; done

_cron_col_ids[__cron:0]="cj-001"
_cron_col_ids[__cron:1]="cr-001"
_cron_col_ids[__cron:2]="cr-002"
_cron_col_ids[__cron:3]="cr-003"
_cron_col_cnt[__cron:0]=1
_cron_col_cnt[__cron:1]=1
_cron_col_cnt[__cron:2]=1
_cron_col_cnt[__cron:3]=1

_list_build_items
echo "${#_list_items[@]}"
for item in "${_list_items[@]}"; do echo "$item"; done
SCRIPT
)
item_count_shown=$(echo "$result_cron_shown" | head -1)
assert_eq "reviewed cron runs visible when _show_done=1 (count=6)" "6" "$item_count_shown"
echo "$result_cron_shown" | grep -q 'cron:cr-003'
assert_eq "cr-003 (reviewed) in list when _show_done=1" "0" "$?"

# ── L: Cron split pane functions ──────────────────────────────────────────

echo ""
echo "L: Cron split pane functions"

# _split_open_cron function present
grep -q '_split_open_cron()' "$BOARD"
assert_eq "_split_open_cron function present" "0" "$?"

# _split_open_cron activates cron dock state
result_cron_flag=$(sed -n '/_split_open_cron()/,/^}/p' "$BOARD" | grep -c '_split_activate_state "cron"')
assert_eq "_split_open_cron activates cron dock state" "1" "$(( result_cron_flag >= 1 ? 1 : 0 ))"

# _split_open activates task dock state
result_task_flag=$(sed -n '/_split_open() {/,/^}/p' "$BOARD" | grep -c '_split_activate_state "task"')
assert_eq "_split_open activates task dock state" "1" "$(( result_task_flag >= 1 ? 1 : 0 ))"

# _split_close resets split state via helper
result_close_flag=$(sed -n '/_split_close()/,/^}/p' "$BOARD" | grep -c '_split_reset_state' || true)
assert_eq "_split_close delegates reset to _split_reset_state" "1" "$(( result_close_flag >= 1 ? 1 : 0 ))"

# _split_break_name uses resume- prefix for cron windows
grep -q '_split_break_name' "$BOARD"
assert_eq "_split_break_name helper present" "0" "$?"
grep -q 'resume-\${dock_id}' "$BOARD"
assert_eq "_split_break_name uses resume- prefix for cron" "0" "$?"

# _split_is_cron state variable in dash loop
grep -q '_split_is_cron=0' "$BOARD"
assert_eq "_split_is_cron state variable initialized" "0" "$?"

# Enter handler for cron uses _split_open_cron
result_enter=$(sed -n '/Cron Enter: open in split/,/;;/p' "$BOARD" | grep -c '_split_open_cron' || true)
assert_eq "Enter on cron run uses _split_open_cron" "1" "$(( result_enter >= 1 ? 1 : 0 ))"

# Enter handler cross-type switching: cron to task
grep -q '_split_is_cron:-0.*==.*1' "$BOARD"
assert_eq "Enter cross-type switch: cron to task" "0" "$?"

# b key handles cron items via _split_open_cron
result_b=$(grep -c '_split_open_cron' "$BOARD" || true)
assert_eq "b key opens split for cron items (5 refs)" "1" "$(( result_b >= 5 ? 1 : 0 ))"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "M: Cron follow type and kanban-to-list cron transfer"

# _list_follow_type defaults to "task"
grep -q '_list_follow_type="task"' "$BOARD"
assert_eq "_list_follow_type defaults to task" "0" "$?"

# _list_follow_type used in follow target construction
grep -q '${_list_follow_type:-task}:${_list_follow_id}' "$BOARD"
assert_eq "follow target uses _list_follow_type prefix" "0" "$?"

# _list_follow_type reset to task after follow completes
result_reset=$(sed -n '/Follow cursor to tracked item/,/^  fi/p' "$BOARD" | grep -c '_list_follow_type="task"' || true)
assert_eq "_list_follow_type reset after follow" "1" "$result_reset"

# _list_follow_id with type cron positions cursor on cron item
result_cron_follow=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_cols _repo_col_cnt _repo_task_count _repo_stale
typeset -A _cron_col_ids _cron_col_cnt _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _list_group_collapsed
local -a _repo_names _list_items
local _show_done=0 _list_cursor=0 _list_follow_id="" _list_follow_type="task"
local _total_task_count=0 _active_count=0 _review_count=0

_repo_names=(myrepo)
_task_status[t-001]="active"; _task_repo[t-001]="myrepo"
_task_status_at[t-001]="2026-01-01T00:00:00Z"
_repo_cols[myrepo:1]="t-001"
_repo_col_cnt[myrepo:1]=1
for _ci in {0..3}; do
  _cron_col_ids[__cron:${_ci}]=""
  _cron_col_cnt[__cron:${_ci}]=0
done
_cron_col_ids[__cron:1]="cr-001"
_cron_col_cnt[__cron:1]=1

# Pre-set follow to cron item
_list_follow_id="cr-001"
_list_follow_type="cron"
_list_build_items

echo "${_list_items[$_list_cursor]}"
SCRIPT
)
assert_eq "cron follow positions cursor on cron:cr-001" "cron:cr-001" "$result_cron_follow"

# _list_transfer_from_kanban preserves pre-set _list_follow_id
result_preserve=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_cols _repo_col_cnt _repo_task_count _repo_stale
typeset -A _cron_col_ids _cron_col_cnt _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _list_group_collapsed _repo_collapsed _repo_paths _repo_types
typeset -A cur_card_row _scroll_top
local -a _repo_names _list_items
local _show_done=0 _list_cursor=0 _list_follow_id="" _list_follow_type="task"
local _total_task_count=0 _active_count=0 _review_count=0
local -i cron_row_selected=0 cur_repo_idx=0 cur_col=0
local nav_mode="card" filter_mode="all" _tid=""

_repo_names=(myrepo)
_task_status[t-001]="active"; _task_repo[t-001]="myrepo"
_task_status_at[t-001]="2026-01-01T00:00:00Z"
_repo_cols[myrepo:1]="t-001"
_repo_col_cnt[myrepo:1]=1
for _ci in {0..3}; do
  _cron_col_ids[__cron:${_ci}]=""
  _cron_col_cnt[__cron:${_ci}]=0
done
_cron_col_ids[__cron:1]="cr-001"
_cron_col_cnt[__cron:1]=1

# Pre-set follow ID (simulating kanban cron Enter handler)
_list_follow_id="cr-001"
_list_follow_type="cron"
_list_transfer_from_kanban

echo "${_list_items[$_list_cursor]}"
SCRIPT
)
assert_eq "transfer preserves pre-set cron follow" "cron:cr-001" "$result_preserve"

# __cron group auto-expands when navigating to cron item
result_expand=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_cols _repo_col_cnt _repo_task_count _repo_stale
typeset -A _cron_col_ids _cron_col_cnt _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _list_group_collapsed _repo_collapsed _repo_paths _repo_types
typeset -A cur_card_row _scroll_top
local -a _repo_names _list_items
local _show_done=0 _list_cursor=0 _list_follow_id="" _list_follow_type="task"
local _total_task_count=0 _active_count=0 _review_count=0
local -i cron_row_selected=0 cur_repo_idx=0 cur_col=0
local nav_mode="card" filter_mode="all" _tid=""

_repo_names=()
for _ci in {0..3}; do
  _cron_col_ids[__cron:${_ci}]=""
  _cron_col_cnt[__cron:${_ci}]=0
done
_cron_col_ids[__cron:1]="cr-001"
_cron_col_cnt[__cron:1]=1

# Start with __cron collapsed
_list_group_collapsed[__cron]=1
_list_follow_id="cr-001"
_list_follow_type="cron"
_list_transfer_from_kanban

echo "${_list_group_collapsed[__cron]:-unset}"
SCRIPT
)
assert_eq "__cron group auto-expands for cron follow" "unset" "$result_expand"

# Kanban cron Enter handler sets _list_follow_type to cron
grep -q '_list_follow_type="cron"' "$BOARD"
assert_eq "kanban cron Enter sets _list_follow_type=cron" "0" "$?"

# Kanban cron Enter switches _view_mode to list
result_viewmode=$(sed -n '/Active .* Needs Review .* Done: open in split/,/;;/p' "$BOARD" | grep -c '_view_mode="list"' || true)
assert_eq "kanban cron Enter switches to list mode" "1" "$result_viewmode"

# ── M: Navigation hot path ─────────────────────────────────────────────────

echo ""
echo "M: Navigation hot path"

result_nav_down=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

typeset -A _list_group_collapsed _task_repo _repo_stale _cron_run_data _cron_jobs _cron_job_enabled _cron_job_schedule
local -a _list_items
local _list_cursor=0 _list_scroll_top=0 _show_done=0 _list_follow_id="" _list_follow_type="task"
local _split_task_id="t-001"
local -i _split_active=1 _split_is_cron=0 _list_needs_rebuild=0
local sync_calls=0

_split_sync_state() { sync_calls=$((sync_calls + 1)); }

_list_items=("task:t-001" "task:t-002")
_list_handle_key "j"

echo "${_list_cursor}:${sync_calls}:${_list_needs_rebuild}"
SCRIPT
)
assert_eq "j moves cursor without split sync or rebuild" "1:0:0" "$result_nav_down"

result_nav_up=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS TYPESET_SILENT
source "$2"

typeset -A _list_group_collapsed _task_repo _repo_stale _cron_run_data _cron_jobs _cron_job_enabled _cron_job_schedule
local -a _list_items
local _list_cursor=1 _list_scroll_top=0 _show_done=0 _list_follow_id="" _list_follow_type="task"
local _split_task_id="t-001"
local -i _split_active=1 _split_is_cron=0 _list_needs_rebuild=0
local sync_calls=0

_split_sync_state() { sync_calls=$((sync_calls + 1)); }

_list_items=("task:t-001" "task:t-002")
_list_handle_key "k"

echo "${_list_cursor}:${sync_calls}:${_list_needs_rebuild}"
SCRIPT
)
assert_eq "k moves cursor without split sync or rebuild" "0:0:0" "$result_nav_up"

result_no_sync=$(sed -n '/_list_handle_key()/,/^}/p' "$BOARD" | grep -c '_split_sync_state' || true)
assert_eq "_list_handle_key no longer calls _split_sync_state" "0" "$result_no_sync"

grep -q 'DASH_ESC_READ_TIMEOUT' "$BOARD"
assert_eq "arrow-key timeout constant present" "0" "$?"

grep -q 'read -rsk2 -t "\$DASH_ESC_READ_TIMEOUT"' "$BOARD"
assert_eq "arrow-key parser uses reduced timeout constant" "0" "$?"

grep -q '_snapshot_dirty -eq 1' "$BOARD"
assert_eq "dashboard loop gates snapshot rebuilds" "0" "$?"

grep -q '_list_needs_rebuild -eq 1' "$BOARD"
assert_eq "dashboard loop gates list rebuilds" "0" "$?"

grep -q 'snapshot=' "$BOARD"
assert_eq "debug log includes snapshot timing" "0" "$?"

grep -q 'dock_sync=' "$BOARD"
assert_eq "debug log includes dock timing" "0" "$?"

grep -q 'input_parse=' "$BOARD"
assert_eq "debug log includes input parse timing" "0" "$?"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: ${pass}/${total} passed, ${fail} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ $fail -eq 0 ]] || exit 1
