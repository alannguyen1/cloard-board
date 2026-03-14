#!/usr/bin/env zsh
# Tests for session history feature:
#   A: Source structure (new functions present)
#   B: Migration (v3 to v4)
#   C: push_session_history
#   D: get_session_history
#   E: set_session_uid_from_history
#   F: cmd__capture_session_uid
#   G: UI integration (H key, footer, help, modal)
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

# Extract functions from built script, stripping main() dispatch and readonly
# on path constants so the test can override GLOBAL_STATE/GLOBAL_DIR
BOARD_SRC="$TMPDIR_TEST/board_src.zsh"
sed -e '/^main "\$@"$/d' \
    -e 's/^readonly GLOBAL_DIR=.*/GLOBAL_DIR="${GLOBAL_DIR:-\/tmp}"/' \
    -e 's/^readonly GLOBAL_STATE=.*/GLOBAL_STATE="${GLOBAL_STATE:-\/tmp\/state.json}"/' \
    -e 's/^readonly HOOKS_DIR=.*/HOOKS_DIR="${HOOKS_DIR:-\/tmp\/hooks}"/' \
    -e 's/^readonly HOOK_VERSION=.*/HOOK_VERSION="${HOOK_VERSION:-2}"/' \
    -e 's/^readonly MAX_SESSION_HISTORY=.*/MAX_SESSION_HISTORY="${MAX_SESSION_HISTORY:-10}"/' \
    "$BOARD" > "$BOARD_SRC"

# ── A: Source structure ──────────────────────────────────────────────────────
echo "A: Source structure"

assert_match "MAX_SESSION_HISTORY constant" "readonly MAX_SESSION_HISTORY=10" "$(grep 'MAX_SESSION_HISTORY' "$BOARD")"

assert_match "push_session_history function" "^push_session_history\(\)" "$(grep 'push_session_history()' "$BOARD")"

assert_match "get_session_history function" "^get_session_history\(\)" "$(grep 'get_session_history()' "$BOARD")"

assert_match "set_session_uid_from_history function" "^set_session_uid_from_history\(\)" "$(grep 'set_session_uid_from_history()' "$BOARD")"

assert_match "_session_history_modal function" "_session_history_modal\(\)" "$(grep '_session_history_modal()' "$BOARD")"

assert_match "_session_file_mtime function" "_session_file_mtime\(\)" "$(grep '_session_file_mtime()' "$BOARD")"

assert_match "Session history modal source file" "156-session-history-modal" "$(ls "$SCRIPT_DIR/../src/156-session-history-modal.sh" 2>/dev/null)"

# ── B: Migration (v3 to v4) ─────────────────────────────────────────────────
echo ""
echo "B: Migration (v3 to v4)"

# B1: Task with session_uid gets session_history
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":3,"next_task_id":2,"next_cron_id":1,"next_run_id":1,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":"abc-123"}],"cron_jobs":[],"cron_runs":[]}
JSON
_migrate_v3_to_v4 >/dev/null
jq -r '.tasks[0].session_history | join(",")' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "v3 task with session_uid gets session_history" "abc-123" "$result"

# B2: Task without session_uid gets empty session_history
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":3,"next_task_id":2,"next_cron_id":1,"next_run_id":1,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"pending"}],"cron_jobs":[],"cron_runs":[]}
JSON
_migrate_v3_to_v4 >/dev/null
jq -r '.tasks[0].session_history | length' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "v3 task without session_uid gets empty history" "0" "$result"

# B3: Version bumped to 4
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":3,"next_task_id":2,"next_cron_id":1,"next_run_id":1,"repos":[],"tasks":[],"cron_jobs":[],"cron_runs":[]}
JSON
_migrate_v3_to_v4 >/dev/null
jq -r '.version' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "version bumped to 4" "4" "$result"

# B4: Task with null session_uid gets empty history
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":3,"next_task_id":2,"next_cron_id":1,"next_run_id":1,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"pending","session_uid":null}],"cron_jobs":[],"cron_runs":[]}
JSON
_migrate_v3_to_v4 >/dev/null
jq -r '.tasks[0].session_history | length' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "v3 task with null session_uid gets empty history" "0" "$result"

# B5: ensure_global_state creates v4 schema
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
HOOKS_DIR="$GLOBAL_DIR/hooks"
# Prevent hook installation
mkdir -p "$HOOKS_DIR"
echo '# hook-version:999' > "$HOOKS_DIR/on-prompt.sh"
touch "$HOOKS_DIR/on-stop.sh"
HOOK_VERSION=999
ensure_global_state >/dev/null
jq -r '.version' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "ensure_global_state creates v5 for new state" "5" "$result"

# B6: ensure_global_state migrates v3 to v4
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
HOOKS_DIR="$GLOBAL_DIR/hooks"
mkdir -p "$HOOKS_DIR"
echo '# hook-version:999' > "$HOOKS_DIR/on-prompt.sh"
touch "$HOOKS_DIR/on-stop.sh"
HOOK_VERSION=999
cat > "$GLOBAL_STATE" <<'JSON'
{"version":3,"next_task_id":1,"next_cron_id":1,"next_run_id":1,"repos":[],"tasks":[],"cron_jobs":[],"cron_runs":[]}
JSON
ensure_global_state >/dev/null
jq -r '.version' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "ensure_global_state migrates v3 to v5" "5" "$result"

# ── C: push_session_history ──────────────────────────────────────────────────
echo ""
echo "C: push_session_history"

# C1: Push to empty history
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":null,"session_history":[]}],"cron_jobs":[],"cron_runs":[]}
JSON
push_session_history "t-001" "uid-aaa"
jq -r '.tasks[0].session_history | join(",")' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "push to empty history" "uid-aaa" "$result"

# C2: Push to existing history (prepends)
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":"uid-aaa","session_history":["uid-aaa"]}],"cron_jobs":[],"cron_runs":[]}
JSON
push_session_history "t-001" "uid-bbb"
jq -r '.tasks[0].session_history | join(",")' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "push prepends to existing history" "uid-bbb,uid-aaa" "$result"

# C3: Push deduplicates (existing UID moves to front)
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":"uid-bbb","session_history":["uid-bbb","uid-aaa","uid-ccc"]}],"cron_jobs":[],"cron_runs":[]}
JSON
push_session_history "t-001" "uid-aaa"
jq -r '.tasks[0].session_history | join(",")' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "push deduplicates (moves to front)" "uid-aaa,uid-bbb,uid-ccc" "$result"

# C4: Push caps at MAX_SESSION_HISTORY
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
# Create history with 10 entries
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":"u01","session_history":["u01","u02","u03","u04","u05","u06","u07","u08","u09","u10"]}],"cron_jobs":[],"cron_runs":[]}
JSON
push_session_history "t-001" "u-new"
jq -r '.tasks[0].session_history | length' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "push caps at MAX_SESSION_HISTORY (10)" "10" "$result"

# C5: session_uid stays in sync
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":"old","session_history":["old"]}],"cron_jobs":[],"cron_runs":[]}
JSON
push_session_history "t-001" "new-uid"
jq -r '.tasks[0].session_uid' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "session_uid syncs to history[0]" "new-uid" "$result"

# C6: Push without prior session_history field
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active"}],"cron_jobs":[],"cron_runs":[]}
JSON
push_session_history "t-001" "uid-new"
jq -r '.tasks[0].session_history | join(",")' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "push initializes session_history if absent" "uid-new" "$result"

# C7: Cap drops oldest entry
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":"u01","session_history":["u01","u02","u03","u04","u05","u06","u07","u08","u09","u10"]}],"cron_jobs":[],"cron_runs":[]}
JSON
push_session_history "t-001" "u-new"
# u10 should be dropped
jq -r '.tasks[0].session_history[-1]' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "cap drops oldest entry (u10 dropped)" "u09" "$result"

# ── D: get_session_history ───────────────────────────────────────────────────
echo ""
echo "D: get_session_history"

# D1: Returns UIDs newest first
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":"uid-c","session_history":["uid-c","uid-b","uid-a"]}],"cron_jobs":[],"cron_runs":[]}
JSON
get_session_history "t-001" | tr '\n' ','
SCRIPT
)
assert_eq "returns UIDs newest first" "uid-c,uid-b,uid-a," "$result"

# D2: Fallback for pre-migration task (no session_history)
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":3,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":"old-uid"}],"cron_jobs":[],"cron_runs":[]}
JSON
get_session_history "t-001"
SCRIPT
)
assert_eq "fallback: returns session_uid when no history" "old-uid" "$result"

# D3: Returns empty for task with no session
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"pending","session_uid":null,"session_history":[]}],"cron_jobs":[],"cron_runs":[]}
JSON
result=$(get_session_history "t-001" || true)
echo "empty:${#result}"
SCRIPT
)
assert_eq "empty for task with no sessions" "empty:0" "$result"

# ── E: set_session_uid_from_history ──────────────────────────────────────────
echo ""
echo "E: set_session_uid_from_history"

# E1: Promotes entry to front
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":"uid-c","session_history":["uid-c","uid-b","uid-a"]}],"cron_jobs":[],"cron_runs":[]}
JSON
set_session_uid_from_history "t-001" "uid-a"
jq -r '.tasks[0].session_history | join(",")' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "promotes entry to front" "uid-a,uid-c,uid-b" "$result"

# E2: Updates session_uid
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":"uid-c","session_history":["uid-c","uid-b","uid-a"]}],"cron_jobs":[],"cron_runs":[]}
JSON
set_session_uid_from_history "t-001" "uid-b"
jq -r '.tasks[0].session_uid' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "updates session_uid to match" "uid-b" "$result"

# E3: No-op if UID not in history
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":"uid-c","session_history":["uid-c","uid-b"]}],"cron_jobs":[],"cron_runs":[]}
JSON
set_session_uid_from_history "t-001" "uid-nonexistent"
jq -r '.tasks[0].session_uid' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "no-op if UID not in history" "uid-c" "$result"

# ── F: cmd__capture_session_uid ──────────────────────────────────────────────
echo ""
echo "F: cmd__capture_session_uid"

# F1: Detects new session (UID differs from current)
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"

# Create a fake project dir with a session file
FAKE_REPO=$(mktemp -d)
encoded="${FAKE_REPO//\//-}"
encoded="${encoded// /-}"
PROJ_DIR="$HOME/.claude/projects/${encoded}"
mkdir -p "$PROJ_DIR"
touch -t 202603041400 "$PROJ_DIR/new-session-uid.jsonl"

cat > "$GLOBAL_STATE" <<JSON
{"version":4,"next_task_id":2,"repos":[{"name":"fakerepo","path":"$FAKE_REPO","type":"git"}],"tasks":[{"id":"t-001","title":"test","repo":"fakerepo","status":"active","session_uid":"old-uid","session_history":["old-uid"]}],"cron_jobs":[],"cron_runs":[]}
JSON

cmd__capture_session_uid "t-001"
jq -r '.tasks[0].session_uid' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "detects new session UID" "new-session-uid" "$result"

# F2: No-op when same UID
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"

FAKE_REPO=$(mktemp -d)
encoded="${FAKE_REPO//\//-}"
encoded="${encoded// /-}"
PROJ_DIR="$HOME/.claude/projects/${encoded}"
mkdir -p "$PROJ_DIR"
touch "$PROJ_DIR/same-uid.jsonl"

cat > "$GLOBAL_STATE" <<JSON
{"version":4,"next_task_id":2,"repos":[{"name":"fakerepo2","path":"$FAKE_REPO","type":"git"}],"tasks":[{"id":"t-001","title":"test","repo":"fakerepo2","status":"active","session_uid":"same-uid","session_history":["same-uid"]}],"cron_jobs":[],"cron_runs":[]}
JSON

cmd__capture_session_uid "t-001"
# History should still be just one entry
jq -r '.tasks[0].session_history | length' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "no-op when same UID (history length unchanged)" "1" "$result"

# F3: Cross-task collision guard
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"

FAKE_REPO=$(mktemp -d)
encoded="${FAKE_REPO//\//-}"
encoded="${encoded// /-}"
PROJ_DIR="$HOME/.claude/projects/${encoded}"
mkdir -p "$PROJ_DIR"
touch "$PROJ_DIR/shared-uid.jsonl"

cat > "$GLOBAL_STATE" <<JSON
{"version":4,"next_task_id":3,"repos":[{"name":"fakerepo3","path":"$FAKE_REPO","type":"git"}],"tasks":[{"id":"t-001","title":"task1","repo":"fakerepo3","status":"active","session_uid":"shared-uid","session_history":["shared-uid"]},{"id":"t-002","title":"task2","repo":"fakerepo3","status":"active","session_uid":"other-uid","session_history":["other-uid"]}],"cron_jobs":[],"cron_runs":[]}
JSON

# t-002 should NOT claim "shared-uid" since t-001 already has it
cmd__capture_session_uid "t-002"
jq -r '.tasks[1].session_uid' "$GLOBAL_STATE"
SCRIPT
)
assert_eq "cross-task collision guard: skips claimed UID" "other-uid" "$result"

# ── G: UI integration ───────────────────────────────────────────────────────
echo ""
echo "G: UI integration"

# G1: H key in help text (Card-level section)
assert_match "H key in help text" "H.*Browse session history" "$(grep 'H.*Browse session history' "$BOARD" | head -1)"

# G2: H key handler in dash
assert_match "H key handler in dash loop" 'H\) # Session history' "$(grep 'H) # Session history' "$BOARD")"

# G3: Footer mentions H
assert_match "footer includes H: history" "H: history" "$(grep 'H: history' "$BOARD" | head -1)"

# G4: Modal source contains _session_history_modal
assert_match "modal contains _session_history_modal" "_session_history_modal" "$(grep '_session_history_modal' "$SCRIPT_DIR/../src/156-session-history-modal.sh" | head -1)"

# G5: Session history in list mode help
assert_match "H key in list mode help" "H.*Browse session history" "$(grep -A20 'List view:' "$BOARD" | grep 'H.*Browse session history')"

# G6: cmd_session creates session_history in jq
assert_match "cmd_session includes session_history" "session_history:.*uid" "$(grep 'session_history:.*uid' "$BOARD" | head -1)"

# G7: _session_file_mtime function exists
assert_match "_session_file_mtime function exists" "_session_file_mtime" "$(grep '_session_file_mtime()' "$BOARD")"

# ── H: Enter guard and H key session launch ─────────────────────────────────
echo ""
echo "H: Enter guard and H key session launch"

# H1: Enter handler has _view_mode guard (prevents double-dispatch in list mode)
assert_match "Enter handler has kanban guard" \
  '_view_mode.*!=.*kanban' \
  "$(grep -A1 'Enter.*kanban only' "$BOARD" | head -2)"

# H2: H key handler checks _session_history_modal return value
assert_match "H handler checks modal return" \
  'if _session_history_modal' \
  "$(grep 'if _session_history_modal' "$BOARD")"

# H3: H key handler kills existing window after session switch
assert_match "H handler kills old window" \
  'tmux_kill_window.*sel_id' \
  "$(sed -n '/H) # Session history/,/;;/p' "$BOARD" | grep 'tmux_kill_window')"

# H4: H key handler builds resume command after session switch
assert_match "H handler builds resume cmd" \
  '_build_claude_resume_cmd.*sel_id' \
  "$(sed -n '/H) # Session history/,/;;/p' "$BOARD" | grep '_build_claude_resume_cmd')"

# H5: H key handler launches Claude with new session
assert_match "H handler launches Claude" \
  '_tmux_launch_claude.*sel_id' \
  "$(sed -n '/H) # Session history/,/;;/p' "$BOARD" | grep '_tmux_launch_claude' | head -1)"

# H6: H key handler handles split pane case
assert_match "H handler handles split pane" \
  '_split_close' \
  "$(sed -n '/H) # Session history/,/;;/p' "$BOARD" | grep '_split_close')"

# H7: H key handler re-opens split after session switch
assert_match "H handler re-opens split" \
  '_split_open.*sel_id' \
  "$(sed -n '/H) # Session history/,/;;/p' "$BOARD" | grep '_split_open')"

# H8: H key handler switches to window in non-split case
assert_match "H handler switches to window" \
  'tmux_select_window.*sel_id' \
  "$(sed -n '/H) # Session history/,/;;/p' "$BOARD" | grep 'tmux_select_window')"

# H9: Enter in list mode is NOT handled by kanban handler
# Verify the kanban Enter handler skips when _view_mode != kanban
result=$(sed -n '/Enter.*kanban only/,/;;/p' "$BOARD" | head -5)
assert_match "kanban Enter skips in non-kanban mode" \
  'view_mode.*!=.*kanban.*then' \
  "$result"

# H10: List mode Enter dispatch still works
assert_match "list mode Enter dispatch present" \
  'list_handle_key.*ENTER' \
  "$(grep '_list_handle_key.*ENTER' "$BOARD")"

# H11: set_session_uid_from_history then _build_claude_resume_cmd flow
# When session doesn't exist on disk, falls back to --continue
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":"uid-c","session_history":["uid-c","uid-b","uid-a"]}],"cron_jobs":[],"cron_runs":[]}
JSON
set_session_uid_from_history "t-001" "uid-a"
_build_claude_resume_cmd "t-001"
SCRIPT
)
assert_eq "resume cmd falls back to --continue when session not on disk" \
  "claude --continue --dangerously-skip-permissions" "$result"

# H12: _build_claude_resume_cmd uses --resume when session exists on disk
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
# Create a fake session dir on disk
SESSIONS_ROOT="${HOME}/Library/Application Support/Claude/claude-code-sessions"
FAKE_PROJECT="${SESSIONS_ROOT}/test-project-$$"
mkdir -p "${FAKE_PROJECT}/uid-real"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":4,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":"uid-real","session_history":["uid-real"]}],"cron_jobs":[],"cron_runs":[]}
JSON
result=$(_build_claude_resume_cmd "t-001")
rm -rf "${FAKE_PROJECT}"
echo "$result"
SCRIPT
)
assert_eq "resume cmd uses --resume when session exists on disk" \
  "claude --resume uid-real --dangerously-skip-permissions" "$result"

# H13: _claude_session_exists finds sessions at new location (~/.claude/projects/*/UUID.jsonl)
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
# Create a fake session .jsonl in the new location
FAKE_PROJECT="${HOME}/.claude/projects/test-project-$$"
mkdir -p "${FAKE_PROJECT}"
echo '{}' > "${FAKE_PROJECT}/uid-new-loc.jsonl"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":5,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":"uid-new-loc","session_history":["uid-new-loc"]}],"cron_jobs":[],"cron_runs":[]}
JSON
result=$(_build_claude_resume_cmd "t-001")
rm -rf "${FAKE_PROJECT}"
echo "$result"
SCRIPT
)
assert_eq "resume cmd uses --resume when session exists at new location (.jsonl)" \
  "claude --resume uid-new-loc --dangerously-skip-permissions" "$result"

# H14: _claude_session_exists finds sessions at new location (UUID/ directory)
result=$(run_zsh <<'SCRIPT'
source "$2"
GLOBAL_DIR=$(mktemp -d)
GLOBAL_STATE="$GLOBAL_DIR/state.json"
# Create a fake session directory (no .jsonl) in the new location
FAKE_PROJECT="${HOME}/.claude/projects/test-project-dir-$$"
mkdir -p "${FAKE_PROJECT}/uid-dir-loc"
cat > "$GLOBAL_STATE" <<'JSON'
{"version":5,"next_task_id":2,"repos":[],"tasks":[{"id":"t-001","title":"test","repo":"r","status":"active","session_uid":"uid-dir-loc","session_history":["uid-dir-loc"]}],"cron_jobs":[],"cron_runs":[]}
JSON
result=$(_build_claude_resume_cmd "t-001")
rm -rf "${FAKE_PROJECT}"
echo "$result"
SCRIPT
)
assert_eq "resume cmd uses --resume when session exists at new location (dir)" \
  "claude --resume uid-dir-loc --dangerously-skip-permissions" "$result"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════"
echo "session_history: ${pass}/${total} passed, ${fail} failed"
echo "══════════════════════════════════════════════════"
[[ $fail -eq 0 ]] || exit 1
