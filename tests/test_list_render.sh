#!/usr/bin/env zsh
# Tests that list mode rendering produces a complete frame without null bytes
# or truncation when output via printf '%s'.
set -euo pipefail
setopt KSH_ARRAYS TYPESET_SILENT 2>/dev/null

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

assert_ge() {
  local label="$1" min="$2" actual="$3"
  total=$((total + 1))
  if [[ $actual -ge $min ]]; then
    echo "  ✓ $label (${actual} >= ${min})"
    pass=$((pass + 1))
  else
    echo "  ✗ $label"
    echo "    expected >= $min, got $actual"
    fail=$((fail + 1))
  fi
}

# Helper: run a zsh snippet from a temp file (passes $BOARD as $1, $BOARD_SRC as $2)
run_zsh() {
  local script="$TMPDIR_TEST/test_$$.zsh"
  cat > "$script"
  zsh "$script" "$BOARD" "$BOARD_SRC" 2>/dev/null
}

# Extract functions from built script, stripping main() dispatch and readonly
# on path constants so the test can override GLOBAL_STATE/GLOBAL_DIR
BOARD_SRC="$TMPDIR_TEST/board_src.zsh"
sed -e '/^main "\$@"$/d' \
    -e 's/^readonly GLOBAL_DIR=.*/GLOBAL_DIR="${GLOBAL_DIR:-\/tmp}"/' \
    -e 's/^readonly GLOBAL_STATE=.*/GLOBAL_STATE="${GLOBAL_STATE:-\/tmp\/state.json}"/' \
    -e 's/^readonly HOOKS_DIR=.*/HOOKS_DIR="${HOOKS_DIR:-\/tmp\/hooks}"/' \
    "$BOARD" > "$BOARD_SRC"

# Create test state.json
STATE_FILE="$TMPDIR_TEST/state.json"
cat > "$STATE_FILE" <<'EOF'
{
  "version": 3,
  "next_task_id": 8,
  "next_cron_id": 2,
  "next_run_id": 1,
  "repos": [
    {"name": "alpha", "path": "/tmp/alpha", "type": "dir"},
    {"name": "beta", "path": "/tmp/beta", "type": "dir"}
  ],
  "tasks": [
    {"id": "t-001", "title": "Fix authentication bug", "status": "active", "claude_status": "working", "repo": "alpha", "pr_url": "https://github.com/org/repo/pull/42"},
    {"id": "t-002", "title": "Add unit tests for login", "status": "active", "claude_status": "waiting", "repo": "alpha"},
    {"id": "t-003", "title": "Refactor database layer", "status": "needs_review", "repo": "alpha"},
    {"id": "t-004", "title": "Update README with new API docs", "status": "pending", "repo": "beta"},
    {"id": "t-005", "title": "Implement dark mode toggle", "status": "active", "repo": "beta"},
    {"id": "t-006", "title": "Fix CSS overflow on mobile", "status": "needs_review", "repo": "beta"},
    {"id": "t-007", "title": "Deploy v2.0 to staging", "status": "paused", "repo": "beta"}
  ],
  "cron_jobs": [
    {"id": "cj-001", "name": "nightly-backup", "enabled": true, "schedule_desc": "daily at 02:00"}
  ],
  "cron_runs": []
}
EOF

# ── Frame integrity test ─────────────────────────────────────────────────────

echo ""
echo "List render: frame integrity"

# Run full render in subprocess and capture diagnostics
result=$(run_zsh <<SCRIPT
setopt KSH_ARRAYS TYPESET_SILENT
GLOBAL_STATE="$STATE_FILE"
GLOBAL_DIR="$TMPDIR_TEST"
source "\$2"

# Terminal dimensions
local cols=120
local rows=43

# Snapshot arrays
typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_paths _repo_types _repo_stale _repo_task_count
typeset -A _repo_cols _repo_col_cnt
local -a _repo_names
local _total_task_count=0 _active_count=0 _review_count=0
local _tid=""

# Cron snapshot arrays
typeset -A _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _cron_col_ids _cron_col_cnt
local _has_cron_data=false
local _ci
for _ci in {0..3}; do
  _cron_col_ids["__cron:\${_ci}"]=""
  _cron_col_cnt["__cron:\${_ci}"]=0
done

# List mode state
local _view_mode="list"
local -i _split_active=0
local -i _show_done=0
local -i _list_cursor=0
local -i _list_scroll_top=0
local -a _list_items=()
local _split_task_id=""
local _list_follow_id=""
typeset -A _list_group_collapsed
local -i _list_scrollbar_vh=0
local -i _list_scrollbar_total=0
local -i _list_needs_rebuild=0

# Navigation state
local filter_mode="all"
local -i filter_idx=0
local nav_mode="repo"

# Populate snapshot
_snapshot_tasks

# Build list items
_list_build_items
echo "ITEMS:\${#_list_items[@]}"

# Render frame
local _frame=""
_render_status_bar
echo "STATUS_BAR:\${#_frame}"

_render_list_full
echo "FULL_FRAME:\${#_frame}"

# Write via printf and echo to temp files
printf '%s' "\$_frame" > "$TMPDIR_TEST/frame_printf.bin"
echo -n "\$_frame" > "$TMPDIR_TEST/frame_echo.bin"

local printf_bytes=\$(wc -c < "$TMPDIR_TEST/frame_printf.bin")
local echo_bytes=\$(wc -c < "$TMPDIR_TEST/frame_echo.bin")
echo "PRINTF_BYTES:\${printf_bytes}"
echo "ECHO_BYTES:\${echo_bytes}"

local null_count=\$(tr -cd '\0' < "$TMPDIR_TEST/frame_echo.bin" | wc -c)
null_count=\$(echo "\$null_count" | tr -d ' ')
echo "NULL_BYTES:\${null_count}"

local line_count=\$(echo -n "\$_frame" | grep -c \$'\n' || true)
echo "LINE_COUNT:\${line_count}"

# Check for expected content
[[ "\$_frame" == *"alpha"* ]] && echo "HAS_ALPHA:yes" || echo "HAS_ALPHA:no"
[[ "\$_frame" == *"beta"* ]] && echo "HAS_BETA:yes" || echo "HAS_BETA:no"
SCRIPT
)

# Parse results
items_count=$(echo "$result" | grep '^ITEMS:' | cut -d: -f2)
status_bar_len=$(echo "$result" | grep '^STATUS_BAR:' | cut -d: -f2)
full_frame_len=$(echo "$result" | grep '^FULL_FRAME:' | cut -d: -f2)
printf_bytes=$(echo "$result" | grep '^PRINTF_BYTES:' | cut -d: -f2 | tr -d ' ')
echo_bytes=$(echo "$result" | grep '^ECHO_BYTES:' | cut -d: -f2 | tr -d ' ')
null_count=$(echo "$result" | grep '^NULL_BYTES:' | cut -d: -f2)
line_count=$(echo "$result" | grep '^LINE_COUNT:' | cut -d: -f2)
has_alpha=$(echo "$result" | grep '^HAS_ALPHA:' | cut -d: -f2)
has_beta=$(echo "$result" | grep '^HAS_BETA:' | cut -d: -f2)

assert_ge "list items built" 5 "$items_count"
assert_ge "status bar produced content" 50 "$status_bar_len"
assert_ge "full frame has content" 500 "$full_frame_len"
assert_eq "printf and echo produce same byte count" "$echo_bytes" "$printf_bytes"
assert_ge "printf bytes >= char count" "$full_frame_len" "$printf_bytes"
assert_eq "no null bytes in frame" "0" "$null_count"
assert_ge "frame has multiple lines" 10 "$line_count"
assert_eq "frame contains alpha group" "yes" "$has_alpha"
assert_eq "frame contains beta group" "yes" "$has_beta"

# ── Test with different cursor positions ─────────────────────────────────────

echo ""
echo "List render: cursor positions"

for cursor_pos in 0 1 3 5; do
  pos_result=$(run_zsh <<SCRIPT
setopt KSH_ARRAYS TYPESET_SILENT
GLOBAL_STATE="$STATE_FILE"
GLOBAL_DIR="$TMPDIR_TEST"
source "\$2"

local cols=120 rows=43
typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_paths _repo_types _repo_stale _repo_task_count
typeset -A _repo_cols _repo_col_cnt
local -a _repo_names
local _total_task_count=0 _active_count=0 _review_count=0
local _tid=""
typeset -A _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _cron_col_ids _cron_col_cnt
local _has_cron_data=false
local _ci
for _ci in {0..3}; do
  _cron_col_ids["__cron:\${_ci}"]=""
  _cron_col_cnt["__cron:\${_ci}"]=0
done
local _view_mode="list"
local -i _split_active=0 _show_done=0 _list_cursor=$cursor_pos _list_scroll_top=0
local -a _list_items=()
local _split_task_id="" _list_follow_id=""
typeset -A _list_group_collapsed
local -i _list_scrollbar_vh=0 _list_scrollbar_total=0 _list_needs_rebuild=0
local filter_mode="all"
local -i filter_idx=0
local nav_mode="repo"

_snapshot_tasks
_list_build_items

local _frame=""
_render_status_bar
_render_list_full

printf '%s' "\$_frame" > "$TMPDIR_TEST/frame_pos_${cursor_pos}.bin"
local pos_bytes=\$(wc -c < "$TMPDIR_TEST/frame_pos_${cursor_pos}.bin" | tr -d ' ')
echo "BYTES:\${pos_bytes}"
SCRIPT
  )

  pos_bytes=$(echo "$pos_result" | grep '^BYTES:' | cut -d: -f2 | tr -d ' ')
  assert_ge "cursor=$cursor_pos: printf output has content" 500 "$pos_bytes"
done

# ── Test with narrow width (narrow format code path) ─────────────────────────

echo ""
echo "List render: narrow format"

narrow_result=$(run_zsh <<SCRIPT
setopt KSH_ARRAYS TYPESET_SILENT
GLOBAL_STATE="$STATE_FILE"
GLOBAL_DIR="$TMPDIR_TEST"
source "\$2"

local cols=30 rows=43
typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_paths _repo_types _repo_stale _repo_task_count
typeset -A _repo_cols _repo_col_cnt
local -a _repo_names
local _total_task_count=0 _active_count=0 _review_count=0
local _tid=""
typeset -A _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _cron_col_ids _cron_col_cnt
local _has_cron_data=false
local _ci
for _ci in {0..3}; do
  _cron_col_ids["__cron:\${_ci}"]=""
  _cron_col_cnt["__cron:\${_ci}"]=0
done
local _view_mode="list"
local -i _split_active=0 _show_done=0 _list_cursor=0 _list_scroll_top=0
local -a _list_items=()
local _split_task_id="" _list_follow_id=""
typeset -A _list_group_collapsed
local -i _list_scrollbar_vh=0 _list_scrollbar_total=0 _list_needs_rebuild=0
local filter_mode="all"
local -i filter_idx=0
local nav_mode="repo"

_snapshot_tasks
_list_build_items

local _frame=""
_render_status_bar
_render_list_full

printf '%s' "\$_frame" > "$TMPDIR_TEST/frame_narrow.bin"
local narrow_bytes=\$(wc -c < "$TMPDIR_TEST/frame_narrow.bin" | tr -d ' ')
local null_count=\$(tr -cd '\0' < "$TMPDIR_TEST/frame_narrow.bin" | wc -c | tr -d ' ')
echo "BYTES:\${narrow_bytes}"
echo "NULL:\${null_count}"
SCRIPT
)

narrow_bytes=$(echo "$narrow_result" | grep '^BYTES:' | cut -d: -f2 | tr -d ' ')
narrow_null=$(echo "$narrow_result" | grep '^NULL:' | cut -d: -f2)
assert_ge "narrow: printf output has content" 200 "$narrow_bytes"
assert_eq "narrow: no null bytes" "0" "$narrow_null"

# ── Test sidebar rendering ───────────────────────────────────────────────────

echo ""
echo "List render: sidebar mode"

sidebar_result=$(run_zsh <<SCRIPT
setopt KSH_ARRAYS TYPESET_SILENT
GLOBAL_STATE="$STATE_FILE"
GLOBAL_DIR="$TMPDIR_TEST"
source "\$2"

local cols=40 rows=43
typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_paths _repo_types _repo_stale _repo_task_count
typeset -A _repo_cols _repo_col_cnt
local -a _repo_names
local _total_task_count=0 _active_count=0 _review_count=0
local _tid=""
typeset -A _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _cron_col_ids _cron_col_cnt
local _has_cron_data=false
local _ci
for _ci in {0..3}; do
  _cron_col_ids["__cron:\${_ci}"]=""
  _cron_col_cnt["__cron:\${_ci}"]=0
done
local _view_mode="list"
local -i _split_active=0 _show_done=0 _list_cursor=0 _list_scroll_top=0
local -a _list_items=()
local _split_task_id="" _list_follow_id=""
typeset -A _list_group_collapsed
local -i _list_scrollbar_vh=0 _list_scrollbar_total=0 _list_needs_rebuild=0
local filter_mode="all"
local -i filter_idx=0
local nav_mode="repo"

_snapshot_tasks
_list_build_items

local _frame=""
_render_status_bar
_render_list_sidebar

printf '%s' "\$_frame" > "$TMPDIR_TEST/frame_sidebar.bin"
local sidebar_bytes=\$(wc -c < "$TMPDIR_TEST/frame_sidebar.bin" | tr -d ' ')
local null_count=\$(tr -cd '\0' < "$TMPDIR_TEST/frame_sidebar.bin" | wc -c | tr -d ' ')
echo "BYTES:\${sidebar_bytes}"
echo "NULL:\${null_count}"
SCRIPT
)

sidebar_bytes=$(echo "$sidebar_result" | grep '^BYTES:' | cut -d: -f2 | tr -d ' ')
sidebar_null=$(echo "$sidebar_result" | grep '^NULL:' | cut -d: -f2)
assert_ge "sidebar: printf output has content" 200 "$sidebar_bytes"
assert_eq "sidebar: no null bytes" "0" "$sidebar_null"

# ── Test split sidebar lines fit pane width ─────────────────────────────────

echo ""
echo "List render: split sidebar width fit"

sidebar_fit_result=$(run_zsh <<SCRIPT
setopt KSH_ARRAYS TYPESET_SILENT
GLOBAL_STATE="$STATE_FILE"
GLOBAL_DIR="$TMPDIR_TEST"
source "\$2"

_time_ago() { _tago='[1h ago]'; }

local cols=38 rows=18
typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_paths _repo_types _repo_stale _repo_task_count
typeset -A _repo_cols _repo_col_cnt
local -a _repo_names
local _total_task_count=0 _active_count=0 _review_count=0
local _tid=""
typeset -A _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _cron_col_ids _cron_col_cnt
local _has_cron_data=false
local _ci
for _ci in {0..3}; do
  _cron_col_ids["__cron:\${_ci}"]=""
  _cron_col_cnt["__cron:\${_ci}"]=0
done
local _view_mode="list"
local -i _split_active=1 _show_done=0 _list_cursor=0 _list_scroll_top=0
local -a _list_items=()
local _split_task_id="t-001" _list_follow_id=""
typeset -A _list_group_collapsed
local -i _list_scrollbar_vh=0 _list_scrollbar_total=0 _list_needs_rebuild=0
local filter_mode="all"
local -i filter_idx=0
local nav_mode="repo"
local _viewport_height=12

_snapshot_tasks
_task_title[t-001]="boringstack product strategy startups"
_task_activity_at[t-001]="2026-03-24T00:00:00Z"
_list_build_items

local _frame=""
_render_list_sidebar

printf '%s' "\$_frame" > "$TMPDIR_TEST/frame_sidebar_fit.bin"
perl -CS -pe 's/\e\[[0-9;]*[[:alpha:]]//g; tr/│┌┐└┘─/||||||/;' "$TMPDIR_TEST/frame_sidebar_fit.bin" > "$TMPDIR_TEST/frame_sidebar_fit_stripped.txt"

local max_len=\$(awk '{ if (length > max) max = length } END { print max + 0 }' "$TMPDIR_TEST/frame_sidebar_fit_stripped.txt")
local min_len=\$(awk 'NR == 1 || length < min { min = length } END { print min + 0 }' "$TMPDIR_TEST/frame_sidebar_fit_stripped.txt")
local overflow=\$(awk -v maxw="\$cols" 'length > maxw { print NR ":" length; exit } END { if (NR == 0) print "empty" }' "$TMPDIR_TEST/frame_sidebar_fit_stripped.txt")
local wrapped_long=\$(grep -c 'startups' "$TMPDIR_TEST/frame_sidebar_fit_stripped.txt" || true)
local ellipsis_line=\$(grep -c 'boringstack produc\\.\\.\\..*\\[1h ago\\]' "$TMPDIR_TEST/frame_sidebar_fit_stripped.txt" || true)

echo "MAX_LEN:\${max_len}"
echo "MIN_LEN:\${min_len}"
echo "OVERFLOW:\${overflow:-none}"
echo "WRAPPED_LONG:\${wrapped_long}"
echo "ELLIPSIS_LINE:\${ellipsis_line}"
SCRIPT
)

sidebar_fit_max=$(echo "$sidebar_fit_result" | grep '^MAX_LEN:' | cut -d: -f2 | tr -d ' ')
sidebar_fit_min=$(echo "$sidebar_fit_result" | grep '^MIN_LEN:' | cut -d: -f2 | tr -d ' ')
sidebar_fit_overflow=$(echo "$sidebar_fit_result" | grep '^OVERFLOW:' | cut -d: -f2- | tr -d ' ')
sidebar_fit_wrapped=$(echo "$sidebar_fit_result" | grep '^WRAPPED_LONG:' | cut -d: -f2 | tr -d ' ')
sidebar_fit_ellipsis=$(echo "$sidebar_fit_result" | grep '^ELLIPSIS_LINE:' | cut -d: -f2 | tr -d ' ')
assert_eq "split sidebar lines stay within pane width" "none" "${sidebar_fit_overflow:-none}"
assert_ge "split sidebar width-fit produced visible lines" 10 "$sidebar_fit_max"
assert_eq "split sidebar width-fit fully paints each line width" "38" "${sidebar_fit_min:-0}"
assert_eq "split sidebar long title does not leak wrapped suffix" "0" "${sidebar_fit_wrapped:-0}"
assert_eq "split sidebar long title truncates with timeago on one line" "1" "${sidebar_fit_ellipsis:-0}"

# ── Test responsive footer selection ────────────────────────────────────────

echo ""
echo "List render: responsive footer selection"

footer_modes_result=$(run_zsh <<SCRIPT
setopt KSH_ARRAYS TYPESET_SILENT
GLOBAL_STATE="$STATE_FILE"
GLOBAL_DIR="$TMPDIR_TEST"
source "\$2"

run_case() {
  local label="\$1"
  local width="\$2"
  local view_mode="\$3"
  local split_active="\$4"
  local filter="\$5"
  local nav="\$6"
  local cron_selected="\${7:-0}"

  local cols="\$width" rows=20
  local _view_mode="\$view_mode"
  local -i _split_active="\$split_active"
  local filter_mode="\$filter"
  local nav_mode="\$nav"
  local -i cron_row_selected="\$cron_selected"
  local _footer_text=""
  local -i _footer_lines=0

  _footer_select_layout

  echo "\${label}_TEXT:\${_footer_text}"
  echo "\${label}_LINES:\${_footer_lines}"
}

run_case "SPLIT_WIDE" 200 "list" 1 "all" "repo"
run_case "SPLIT_MEDIUM" 60 "list" 1 "all" "repo"
run_case "SPLIT_NARROW" 30 "list" 1 "all" "repo"
run_case "LIST_NARROW" 25 "list" 0 "all" "repo"
SCRIPT
)

split_wide_text=$(echo "$footer_modes_result" | grep '^SPLIT_WIDE_TEXT:' | cut -d: -f2-)
split_wide_lines=$(echo "$footer_modes_result" | grep '^SPLIT_WIDE_LINES:' | cut -d: -f2 | tr -d ' ')
split_medium_text=$(echo "$footer_modes_result" | grep '^SPLIT_MEDIUM_TEXT:' | cut -d: -f2-)
split_medium_lines=$(echo "$footer_modes_result" | grep '^SPLIT_MEDIUM_LINES:' | cut -d: -f2 | tr -d ' ')
split_narrow_text=$(echo "$footer_modes_result" | grep '^SPLIT_NARROW_TEXT:' | cut -d: -f2-)
split_narrow_lines=$(echo "$footer_modes_result" | grep '^SPLIT_NARROW_LINES:' | cut -d: -f2 | tr -d ' ')
list_narrow_text=$(echo "$footer_modes_result" | grep '^LIST_NARROW_TEXT:' | cut -d: -f2-)
list_narrow_lines=$(echo "$footer_modes_result" | grep '^LIST_NARROW_LINES:' | cut -d: -f2 | tr -d ' ')

assert_eq "split footer wide keeps full text" \
  "  j/k: nav  Enter/l: focus  Ctrl-F: toggle  F: fullscreen  </> status  r: reopen  t: rename  s: shell  x: done  d: show done  H: history  Tab: filter  b: undock  q: quit" \
  "$split_wide_text"
assert_eq "split footer wide stays on one line" "1" "$split_wide_lines"
assert_eq "split footer medium uses compact text" \
  "j/k nav  Enter/l focus  Ctrl-F toggle  F fullscreen  Tab filter  b undock  q quit" \
  "$split_medium_text"
assert_eq "split footer medium wraps to two lines" "2" "$split_medium_lines"
assert_eq "split footer narrow uses minimal text" \
  "j/k nav  Enter/l focus  b undock  q quit" \
  "$split_narrow_text"
assert_eq "split footer narrow fits in two lines" "2" "$split_narrow_lines"
assert_eq "non-split narrow footer also goes minimal" \
  "j/k nav  Enter open  b dock  q quit" \
  "$list_narrow_text"
assert_eq "non-split narrow footer reserves two lines" "2" "$list_narrow_lines"

footer_paint_result=$(run_zsh <<SCRIPT
setopt KSH_ARRAYS TYPESET_SILENT
GLOBAL_STATE="$STATE_FILE"
GLOBAL_DIR="$TMPDIR_TEST"
source "\$2"

local cols=30 rows=8
local _view_mode="list"
local -i _split_active=1
local filter_mode="all"
local nav_mode="repo"
local _footer_text=""
local -i _footer_lines=0

_footer_select_layout
_footer_print_padded_lines "\$_footer_text" "\$cols" > "$TMPDIR_TEST/footer_paint.txt"
local max_len=\$(awk '{ if (length > max) max = length } END { print max + 0 }' "$TMPDIR_TEST/footer_paint.txt")
local min_len=\$(awk 'NR == 1 || length < min { min = length } END { print min + 0 }' "$TMPDIR_TEST/footer_paint.txt")

echo "PAINT_MAX:\${max_len}"
echo "PAINT_MIN:\${min_len}"
SCRIPT
)

footer_paint_max=$(echo "$footer_paint_result" | grep '^PAINT_MAX:' | cut -d: -f2 | tr -d ' ')
footer_paint_min=$(echo "$footer_paint_result" | grep '^PAINT_MIN:' | cut -d: -f2 | tr -d ' ')
assert_eq "responsive footer paint fills full width" "30" "$footer_paint_max"
assert_eq "responsive footer paint clears trailing chars on wrapped lines" "30" "$footer_paint_min"

# ── Test split sidebar frame keeps footer reserve ───────────────────────────

echo ""
echo "List render: split sidebar footer reserve"

split_footer_result=$(run_zsh <<SCRIPT
setopt KSH_ARRAYS TYPESET_SILENT
GLOBAL_STATE="$STATE_FILE"
GLOBAL_DIR="$TMPDIR_TEST"
source "\$2"

local cols=38 rows=14
typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_paths _repo_types _repo_stale _repo_task_count
typeset -A _repo_cols _repo_col_cnt
local -a _repo_names
local _total_task_count=0 _active_count=0 _review_count=0
local _tid=""
typeset -A _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _cron_col_ids _cron_col_cnt
local _has_cron_data=false
local _ci
for _ci in {0..3}; do
  _cron_col_ids["__cron:\${_ci}"]=""
  _cron_col_cnt["__cron:\${_ci}"]=0
done
local _view_mode="list"
local -i _split_active=1 _show_done=0 _list_cursor=0 _list_scroll_top=0
local -a _list_items=()
local _split_task_id="t-001" _list_follow_id=""
typeset -A _list_group_collapsed
local -i _list_scrollbar_vh=0 _list_scrollbar_total=0 _list_needs_rebuild=0
local filter_mode="all"
local -i filter_idx=0
local nav_mode="repo"

_snapshot_tasks
_list_build_items

local _footer_text=""
local -i _footer_lines=1
_footer_select_layout
local _viewport_height=\$((rows - 1 - _footer_lines))
[[ \$_viewport_height -lt 1 ]] && _viewport_height=1

local _frame=""
_render_status_bar
_render_list_sidebar

local _max_lines=\$((rows - _footer_lines))
local -a _flines
_flines=("\${(@f)_frame}")
if [[ \${#_flines[@]} -gt \$_max_lines ]]; then
  _flines=("\${_flines[@]:0:\$_max_lines}")
fi

perl -pe 's/\e\[[0-9;]*[[:alpha:]]//g' <<< "\${(pj:\n:)_flines[@]}" > "$TMPDIR_TEST/frame_sidebar_footer_stripped.txt"
local overflow=\$(awk -v maxw="\$cols" 'length > maxw { print NR ":" length; exit } END { if (NR == 0) print "empty" }' "$TMPDIR_TEST/frame_sidebar_footer_stripped.txt")

echo "FOOTER_TEXT:\${_footer_text}"
echo "FOOTER_LINES:\${_footer_lines}"
echo "MAX_LINES:\${_max_lines}"
echo "CLIPPED_LINES:\${#_flines[@]}"
echo "OVERFLOW:\${overflow:-none}"
SCRIPT
)

split_footer_text=$(echo "$split_footer_result" | grep '^FOOTER_TEXT:' | cut -d: -f2-)
split_footer_reserved=$(echo "$split_footer_result" | grep '^FOOTER_LINES:' | cut -d: -f2 | tr -d ' ')
split_footer_max=$(echo "$split_footer_result" | grep '^MAX_LINES:' | cut -d: -f2 | tr -d ' ')
split_footer_lines=$(echo "$split_footer_result" | grep '^CLIPPED_LINES:' | cut -d: -f2 | tr -d ' ')
split_footer_overflow=$(echo "$split_footer_result" | grep '^OVERFLOW:' | cut -d: -f2- | tr -d ' ')
assert_eq "split sidebar narrow footer uses minimal variant" "j/k nav  Enter/l focus  b undock  q quit" "$split_footer_text"
assert_eq "split sidebar narrow footer reserves two lines" "2" "$split_footer_reserved"
assert_eq "split sidebar clipped frame preserves footer reserve" "$split_footer_max" "$split_footer_lines"
assert_eq "split sidebar clipped frame stays within pane width" "none" "${split_footer_overflow:-none}"

# ── Test frame clipping preserves content ────────────────────────────────────

echo ""
echo "List render: frame clipping with KSH_ARRAYS"

clip_result=$(run_zsh <<SCRIPT
setopt KSH_ARRAYS TYPESET_SILENT
GLOBAL_STATE="$STATE_FILE"
GLOBAL_DIR="$TMPDIR_TEST"
source "\$2"

# Use small terminal so frame exceeds max_lines and triggers clipping
local cols=120 rows=20
typeset -A _task_status _task_title _task_pr _task_claude _task_wtmode _task_repo _task_status_at _task_activity_at
typeset -A _repo_paths _repo_types _repo_stale _repo_task_count
typeset -A _repo_cols _repo_col_cnt
local -a _repo_names
local _total_task_count=0 _active_count=0 _review_count=0
local _tid=""
typeset -A _cron_jobs _cron_job_enabled _cron_job_schedule _cron_run_data
typeset -A _cron_col_ids _cron_col_cnt
local _has_cron_data=false
local _ci
for _ci in {0..3}; do
  _cron_col_ids["__cron:\${_ci}"]=""
  _cron_col_cnt["__cron:\${_ci}"]=0
done
local _view_mode="list"
local -i _split_active=0 _show_done=0 _list_cursor=0 _list_scroll_top=0
local -a _list_items=()
local _split_task_id="" _list_follow_id=""
typeset -A _list_group_collapsed
local -i _list_scrollbar_vh=0 _list_scrollbar_total=0 _list_needs_rebuild=0
local filter_mode="all"
local -i filter_idx=0
local nav_mode="repo"

_snapshot_tasks
_list_build_items

local _frame=""
_render_status_bar
_render_list_full

local pre_clip=\${#_frame}

# Simulate the exact clipping code from cmd__dash_loop
local _max_lines=\$((rows - 1))
local -a _flines
_flines=("\${(@f)_frame}")
local flines_count=\${#_flines[@]}
if [[ \${#_flines[@]} -gt \$_max_lines ]]; then
  _flines=("\${_flines[@]:0:\$_max_lines}")
  _frame="\${(pj:\n:)_flines[@]}"\$'\n'
fi

local post_clip=\${#_frame}
echo "PRE_CLIP:\${pre_clip}"
echo "POST_CLIP:\${post_clip}"
echo "FLINES:\${flines_count}"
echo "MAX_LINES:\${_max_lines}"
# Post-clip frame should still have significant content (not just status bar)
echo "HAS_TASK:[[ "\$_frame" == *"Fix authentication"* ]] && echo yes || echo no"
[[ "\$_frame" == *"Fix authentication"* ]] && echo "HAS_TASK:yes" || echo "HAS_TASK:no"
SCRIPT
)

clip_pre=$(echo "$clip_result" | grep '^PRE_CLIP:' | cut -d: -f2)
clip_post=$(echo "$clip_result" | grep '^POST_CLIP:' | cut -d: -f2)
clip_flines=$(echo "$clip_result" | grep '^FLINES:' | cut -d: -f2)
clip_max=$(echo "$clip_result" | grep '^MAX_LINES:' | cut -d: -f2)
clip_has_task=$(echo "$clip_result" | grep '^HAS_TASK:' | tail -1 | cut -d: -f2)

assert_ge "pre-clip frame has content" 500 "$clip_pre"
assert_ge "clipping triggered (flines > max)" "$clip_max" "$clip_flines"
assert_ge "post-clip frame retains content" 500 "$clip_post"
assert_eq "post-clip frame has task data" "yes" "$clip_has_task"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: ${pass}/${total} passed, ${fail} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ $fail -eq 0 ]] || exit 1
