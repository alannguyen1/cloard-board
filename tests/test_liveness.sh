#!/usr/bin/env zsh
# Tests for:
#   A: _tmux_claude_alive descendant-process fallback
#   B: Hook versioning in bootstrap
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

# ── Fix A: _tmux_claude_alive descendant-process fallback ──────────────────

echo ""
echo "Fix A: _tmux_claude_alive structure"

# Test: function still exists
grep -q '_tmux_claude_alive()' "$BOARD"
assert_eq "_tmux_claude_alive function exists" "0" "$?"

# Test: fast path still checks pane_current_command (for direct runtimes)
grep -q 'pane_current_command' "$BOARD"
assert_eq "fast path checks pane_current_command" "0" "$?"

# Test: fast path matches claude, node, and bun
grep -q '\[\[ "\$pane_cmd" == \*claude\* || "\$pane_cmd" == \*node\* || "\$pane_cmd" == \*bun\* \]\] && return 0' "$BOARD"
assert_eq "fast path matches claude, node, and bun" "0" "$?"

# Test: fallback uses pane_pid
grep -q '#{pane_pid}' "$BOARD"
assert_eq "fallback fetches pane_pid" "0" "$?"

# Test: helper for per-process matching exists
grep -q '_tmux_process_matches_runtime()' "$BOARD"
assert_eq "runtime matcher helper exists" "0" "$?"

# Test: helper for recursive process-tree walk exists
grep -q '_tmux_process_tree_runtime_alive()' "$BOARD"
assert_eq "process-tree helper exists" "0" "$?"

# Test: process-tree walk uses pgrep recursion
grep -q 'pgrep -P "\$pid"' "$BOARD"
assert_eq "process-tree helper uses pgrep recursion" "0" "$?"

# Test: matcher inspects full command lines as well as comm names
grep -q 'ps eww -o command=' "$BOARD"
assert_eq "runtime matcher checks full command lines" "0" "$?"

# Test: _tmux_pane_claude_alive delegates to the recursive helper
grep -q '_tmux_process_tree_runtime_alive "\$pane_pid"' "$BOARD"
assert_eq "_tmux_pane_claude_alive delegates to process-tree helper" "0" "$?"

echo ""
echo "Fix A: Functional descendant-process detection"

BOARD_SRC="$TMPDIR_TEST/board_src.zsh"
sed '/^main "\$@"$/d' "$BOARD" > "$BOARD_SRC"
source "$BOARD_SRC"

tmux_cmd() {
  if [[ "$*" == *"#{pane_current_command}"* ]]; then
    echo "${MOCK_PANE_COMMAND:-zsh}"
  elif [[ "$*" == *"#{pane_pid}"* ]]; then
    echo "${MOCK_PANE_PID:-100}"
  else
    return 1
  fi
}

MOCK_BIN="$TMPDIR_TEST/bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
parent=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -P) parent="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "${MOCK_SCENARIO:-live}:$parent" in
  live:100) printf '200\n' ;;
  live:200) printf '300\n' ;;
  dead:100) printf '200\n' ;;
  *) ;;
esac
EOF
chmod +x "$MOCK_BIN/pgrep"

cat > "$MOCK_BIN/ps" <<'EOF'
#!/usr/bin/env bash
format=""
pid=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    eww) shift ;;
    -o) format="$2"; shift 2 ;;
    -p) pid="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "${MOCK_SCENARIO:-live}:$format:$pid" in
  live:comm=:100) echo "zsh" ;;
  live:comm=:200) echo "helper" ;;
  live:comm=:300) echo "helper" ;;
  live:command=:100) echo "zsh -c wrapped-runtime" ;;
  live:command=:200) echo "python wrapper.py" ;;
  live:command=:300) echo "/Users/test/.bun/bin/bun /Users/test/.local/bin/claude --resume abc" ;;
  dead:comm=:100) echo "zsh" ;;
  dead:comm=:200) echo "cat" ;;
  dead:command=:100) echo "zsh -c wrapped-shell" ;;
  dead:command=:200) echo "cat" ;;
  *) ;;
esac
EOF
chmod +x "$MOCK_BIN/ps"

PATH="$MOCK_BIN:$PATH"
export MOCK_PANE_COMMAND="zsh"
export MOCK_PANE_PID="100"

export MOCK_SCENARIO="live"
alive_rc=1
_tmux_pane_claude_alive "board:dashboard.1" && alive_rc=0
assert_eq "recursive descendant cmdline counts as live" "0" "$alive_rc"

export MOCK_SCENARIO="dead"
dead_rc=0
_tmux_pane_claude_alive "board:dashboard.1" || dead_rc=$?
assert_eq "fallback shell tree stays dead" "1" "$dead_rc"

# ── Fix B: Ctrl-F binding structure ────────────────────────────────────────

echo ""
echo "Fix B: Ctrl-F binding structure"

# Ctrl-F binding uses if-shell guard for multi-pane safety
grep -q 'C-f.*if-shell' "$BOARD"
assert_eq "Ctrl-F binding has if-shell guard" "0" "$?"

# Ctrl-F binding uses last-pane for toggling
grep -q 'last-pane' "$BOARD"
assert_eq "Ctrl-F uses last-pane" "0" "$?"

# No stale C-s bindings remain
result_cs=$(grep -c 'bind-key.*C-s' "$BOARD" || true)
assert_eq "no C-s bind-key remains" "0" "$result_cs"

result_us=$(grep -c 'unbind-key.*C-s' "$BOARD" || true)
assert_eq "no C-s unbind-key remains" "0" "$result_us"

# ── Fix C: Hook versioning ─────────────────────────────────────────────────

echo ""
echo "Fix C: Hook versioning"

# Test: HOOK_VERSION constant exists
grep -q 'readonly HOOK_VERSION=' "$BOARD"
assert_eq "HOOK_VERSION constant defined" "0" "$?"

# Test: HOOK_VERSION is set to "4"
grep -q 'readonly HOOK_VERSION="4"' "$BOARD"
assert_eq "HOOK_VERSION is 4" "0" "$?"

# Test: on-stop.sh template includes hook-version marker
grep -q 'hook-version:\${HOOK_VERSION}' "$BOARD"
assert_eq "on-stop.sh template has version marker" "0" "$?"

# Test: on-prompt.sh template includes hook-version marker
# Both hooks should have the version marker; check there are at least 2 occurrences
result=$(grep -c 'hook-version:\${HOOK_VERSION}' "$BOARD")
assert_eq "both hooks have version marker" "1" "$(( result >= 2 ? 1 : 0 ))"

# Test: ensure_global_state checks hook version (reads from on-prompt.sh)
grep -q "grep -o 'hook-version:\[0-9\]\*'" "$BOARD"
assert_eq "bootstrap reads hook version from file" "0" "$?"

# Test: version comparison with HOOK_VERSION
grep -q '"\$_hook_ver" != "\$HOOK_VERSION"' "$BOARD"
assert_eq "bootstrap compares version against HOOK_VERSION" "0" "$?"

# Test: stale hook is reinstalled (the condition triggers _install_hook_scripts)
grep -q '_install_hook_scripts' "$BOARD"
assert_eq "_install_hook_scripts called on version mismatch" "0" "$?"

# Test: PostToolUse hooks registered for AskUserQuestion and ExitPlanMode
grep -q '"PostToolUse"' "$BOARD"
assert_eq "PostToolUse hook type registered" "0" "$?"

grep -q '"matcher": "AskUserQuestion"' "$BOARD"
assert_eq "AskUserQuestion matcher registered" "0" "$?"

grep -q '"matcher": "ExitPlanMode"' "$BOARD"
assert_eq "ExitPlanMode matcher registered" "0" "$?"

# Test: Notification hooks registered for idle_prompt and permission_prompt
grep -q '"Notification"' "$BOARD"
assert_eq "Notification hook type registered" "0" "$?"

grep -q '"matcher": "idle_prompt"' "$BOARD"
assert_eq "idle_prompt matcher registered" "0" "$?"

grep -q '"matcher": "permission_prompt"' "$BOARD"
assert_eq "permission_prompt matcher registered" "0" "$?"

# ── Fix B: Functional version extraction simulation ────────────────────────

echo ""
echo "Fix B: Version extraction simulation"

# Create a mock hook file with version marker
mock_hook="$TMPDIR_TEST/on-prompt.sh"
cat > "$mock_hook" <<'EOF'
#!/usr/bin/env bash
# cloard-board hook: set task status to "working" when user submits a prompt
# hook-version:4
[[ -n "${CLOARD_TASK_ID:-}" ]] || exit 0
cloard-board signal "$CLOARD_TASK_ID" working &>/dev/null &
cloard-board _capture-session-uid "$CLOARD_TASK_ID" &>/dev/null &
EOF

# Extract version
extracted=$(grep -o 'hook-version:[0-9]*' "$mock_hook" 2>/dev/null | cut -d: -f2)
assert_eq "extracts version 4 from hook file" "4" "$extracted"

# Create a hook WITHOUT version marker (simulates old/stale hook)
mock_old="$TMPDIR_TEST/on-prompt-old.sh"
cat > "$mock_old" <<'EOF'
#!/usr/bin/env bash
# cloard-board hook: set task status to "working" when user submits a prompt
[[ -n "${CLOARD_TASK_ID:-}" ]] || exit 0
cloard-board signal "$CLOARD_TASK_ID" working &>/dev/null &
EOF

extracted_old=$(grep -o 'hook-version:[0-9]*' "$mock_old" 2>/dev/null | cut -d: -f2 || true)
assert_eq "old hook returns empty version" "" "$extracted_old"

# Version mismatch detection
[[ "$extracted_old" != "4" ]]
assert_eq "stale hook triggers reinstall" "0" "$?"

# Version match: no reinstall needed
[[ "$extracted" != "4" ]] && result="mismatch" || result="match"
assert_eq "current hook passes version check" "match" "$result"

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: ${pass}/${total} passed, ${fail} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ $fail -eq 0 ]] || exit 1
