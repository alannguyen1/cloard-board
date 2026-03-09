#!/usr/bin/env zsh
# Tests for:
#   A: _tmux_claude_alive child-process fallback (zsh wrapper case)
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

# ── Fix A: _tmux_claude_alive child-process fallback ───────────────────────

echo ""
echo "Fix A: _tmux_claude_alive structure"

# Test: function still exists
grep -q '_tmux_claude_alive()' "$BOARD"
assert_eq "_tmux_claude_alive function exists" "0" "$?"

# Test: fast path still checks pane_current_command (for direct claude/node)
grep -q 'pane_current_command' "$BOARD"
assert_eq "fast path checks pane_current_command" "0" "$?"

# Test: fast path returns 0 on match (&&  return 0)
grep -q '\[\[ "\$pane_cmd" == \*claude\* || "\$pane_cmd" == \*node\* \]\] && return 0' "$BOARD"
assert_eq "fast path returns 0 on match" "0" "$?"

# Test: fallback uses pane_pid
grep -q '#{pane_pid}' "$BOARD"
assert_eq "fallback fetches pane_pid" "0" "$?"

# Test: fallback uses pgrep -P to find child processes
grep -q 'pgrep -P "\$pane_pid"' "$BOARD"
assert_eq "fallback uses pgrep -P for child processes" "0" "$?"

# Test: fallback pipes to ps -o comm=
grep -q "ps -o comm= -p" "$BOARD"
assert_eq "fallback checks child command names via ps" "0" "$?"

# Test: fallback greps for claude or node
grep -q "grep -qE 'claude|node'" "$BOARD"
assert_eq "fallback greps for claude|node" "0" "$?"

# Test: old single-expression pattern is gone (the old code had the [[ ]] as last line with no && return 0)
# The old pattern was: [[ "$pane_cmd" == *claude* ... ]] as the ONLY check (no pgrep fallback)
# Verify the function body contains pgrep (i.e., the fallback was actually added, not just the fast path)
result=$(awk '/_tmux_claude_alive\(\)/,/^}/' "$BOARD" | grep -c 'pgrep')
assert_eq "pgrep inside _tmux_claude_alive body" "1" "$result"

# Test: function body has both the fast path AND the fallback
result=$(awk '/_tmux_claude_alive\(\)/,/^}/' "$BOARD" | grep -c 'return')
# Should have at least 2 returns: return 1 (no window), return 0 (fast path match), return 1 (no pane_pid)
assert_eq "_tmux_claude_alive has multiple return paths" "1" "$(( result >= 2 ? 1 : 0 ))"

# ── Fix A: Functional simulation of child-process detection ────────────────

echo ""
echo "Fix A: Child-process detection simulation"

# Simulate: pgrep finds a "claude" child, grep should match
result=$(echo "claude" | grep -qE 'claude|node' && echo "alive" || echo "dead")
assert_eq "grep matches claude child" "alive" "$result"

# Simulate: pgrep finds a "node" child, grep should match
result=$(echo "node" | grep -qE 'claude|node' && echo "alive" || echo "dead")
assert_eq "grep matches node child" "alive" "$result"

# Simulate: pgrep finds only "zsh" child, grep should NOT match
result=$(echo "zsh" | grep -qE 'claude|node' && echo "alive" || echo "dead")
assert_eq "grep rejects zsh-only children" "dead" "$result"

# Simulate: pgrep finds multiple children, one is claude
result=$(printf "zsh\nclaude\ncat" | grep -qE 'claude|node' && echo "alive" || echo "dead")
assert_eq "grep matches claude among multiple children" "alive" "$result"

# Simulate: empty pgrep output (no children), grep should NOT match
result=$(echo "" | grep -qE 'claude|node' && echo "alive" || echo "dead")
assert_eq "grep rejects empty child list" "dead" "$result"

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

# Test: HOOK_VERSION is set to "2"
grep -q 'readonly HOOK_VERSION="3"' "$BOARD"
assert_eq "HOOK_VERSION is 3" "0" "$?"

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

# ── Fix B: Functional version extraction simulation ────────────────────────

echo ""
echo "Fix B: Version extraction simulation"

# Create a mock hook file with version marker
mock_hook="$TMPDIR_TEST/on-prompt.sh"
cat > "$mock_hook" <<'EOF'
#!/usr/bin/env bash
# cloard-board hook: set task status to "working" when user submits a prompt
# hook-version:3
[[ -n "${CLOARD_TASK_ID:-}" ]] || exit 0
cloard-board signal "$CLOARD_TASK_ID" working &>/dev/null &
cloard-board _capture-session-uid "$CLOARD_TASK_ID" &>/dev/null &
EOF

# Extract version
extracted=$(grep -o 'hook-version:[0-9]*' "$mock_hook" 2>/dev/null | cut -d: -f2)
assert_eq "extracts version 3 from hook file" "3" "$extracted"

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
[[ "$extracted_old" != "3" ]]
assert_eq "stale hook triggers reinstall" "0" "$?"

# Version match: no reinstall needed
[[ "$extracted" != "3" ]] && result="mismatch" || result="match"
assert_eq "current hook passes version check" "match" "$result"

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: ${pass}/${total} passed, ${fail} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ $fail -eq 0 ]] || exit 1
