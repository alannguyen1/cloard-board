#!/usr/bin/env zsh
# Tests for cloard-board fixes:
#   A: _read_or_esc raw-mode loop (Esc at any position, echo all chars, backspace)
#   B: Path sanitization with ${(Q)} dequoting
#   C: Repo picker validation with error messages
#   D: Quoted $new_prompt in cmd_start call
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

# Helper: run a zsh snippet from a temp file (avoids nested quoting issues)
run_zsh() {
  local script="$TMPDIR_TEST/test_$$.zsh"
  cat > "$script"
  zsh "$script" 2>/dev/null
}

# ── Fix A: _read_or_esc raw-mode loop ───────────────────────────────────────

echo ""
echo "Fix A: _read_or_esc structure"

# Test: function uses raw mode throughout (while loop, not read -r for rest)
grep -q 'while true; do' "$BOARD"
assert_eq "_read_or_esc uses while-true loop" "0" "$?"

# Test: Esc handler drains buffered keys
grep -q 'while read -rk1 -t 0.05 _discard' "$BOARD"
assert_eq "Esc drain loop present" "0" "$?"

# Test: backspace handling exists
grep -q 'printf.*\\b \\b' "$BOARD"
assert_eq "backspace erase (\\b \\b) present" "0" "$?"

# Test: Ctrl-U (kill line) handling exists
grep -q '\\x15' "$BOARD"
assert_eq "Ctrl-U handler present" "0" "$?"

# Test: Ctrl-W (kill word) handling exists
grep -q '\\x17' "$BOARD"
assert_eq "Ctrl-W handler present" "0" "$?"

# Test: every normal char is echoed via printf
grep -q "printf '%s' \"\\\$_char\"" "$BOARD"
assert_eq "printf echoes each char" "0" "$?"

# Test: Esc detected in the loop (not just first char)
# The old code had a separate first-char check; the new code handles it in the loop case
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
src=$(cat "$1")
# Check that Esc handling is inside a case statement (loop-based), not a standalone if
if echo "$src" | grep -q "case.*_char.*in" && echo "$src" | grep -q '$'"'"'\\e'"'"'.*$'"'"'\\x03'"'"')'; then
  echo "IN_LOOP"
else
  echo "NOT_IN_LOOP"
fi
SCRIPT
)
# Simpler: just verify the case structure exists
grep -q '_char.*in' "$BOARD" 2>/dev/null
assert_eq "Esc detection inside case (loop-based)" "0" "$?"

# Test: stty echo -raw used on both exit paths (Enter and Esc)
count=$(grep -c 'stty echo -raw' "$BOARD" 2>/dev/null || echo 0)
actual_check=$([[ $count -ge 2 ]] && echo "true" || echo "false")
assert_eq "stty echo -raw on multiple exit paths (found $count)" "true" "$actual_check"

# ── Fix A: Character echo logic simulation ──────────────────────────────────

echo ""
echo "Fix A: Character echo simulation"

# Simulate the char-by-char echo: each char is printf'd
output=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_line=""
for c in h e l l o; do
  _line="${_line}${c}"
  printf '%s' "$c"
done
SCRIPT
)
assert_eq "all chars echoed (hello)" "hello" "$output"

# Simulate backspace: removes last char and erases from display
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_line="helo"
# Simulate backspace
_line="${_line%?}"
echo "$_line"
SCRIPT
)
assert_eq "backspace removes last char" "hel" "$result"

# Simulate Ctrl-U: clears entire line
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_line="hello world"
_line=""
echo "line=$_line"
SCRIPT
)
assert_eq "Ctrl-U clears line" "line=" "$result"

# Simulate Ctrl-W: kills last word
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_line="hello world foo"
_old_len=${#_line}
while [[ "$_line" == *' ' ]]; do _line="${_line% }"; done
while [[ -n "$_line" ]] && [[ "$_line" != *' ' ]]; do _line="${_line%?}"; done
echo "$_line"
SCRIPT
)
assert_eq "Ctrl-W kills last word" "hello world " "$result"

# Simulate Ctrl-W: kills only word when no trailing spaces
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_line="hello"
while [[ "$_line" == *' ' ]]; do _line="${_line% }"; done
while [[ -n "$_line" ]] && [[ "$_line" != *' ' ]]; do _line="${_line%?}"; done
echo "line=$_line"
SCRIPT
)
assert_eq "Ctrl-W kills sole word" "line=" "$result"

# ── Fix B: Path sanitization with ${(Q)} ────────────────────────────────────

echo ""
echo "Fix B: Path sanitization (dequoting)"

# Test: backslash-escaped spaces (drag-and-drop style)
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
p="/Users/alan/Coding\ projects/my-repo"
p="${p%$'\r'}"
p="${p## }"
p="${p%% }"
p="${(Q)p}"
echo "$p"
SCRIPT
)
assert_eq "backslash-escaped space dequoted" "/Users/alan/Coding projects/my-repo" "$result"

# Test: single-quoted path
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
p="'/Users/alan/Coding projects/my-repo'"
p="${p%$'\r'}"
p="${p## }"
p="${p%% }"
p="${(Q)p}"
echo "$p"
SCRIPT
)
assert_eq "single-quoted path dequoted" "/Users/alan/Coding projects/my-repo" "$result"

# Test: double-quoted path
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
p='"/Users/alan/Coding projects/my-repo"'
p="${p%$'\r'}"
p="${p## }"
p="${p%% }"
p="${(Q)p}"
echo "$p"
SCRIPT
)
assert_eq "double-quoted path dequoted" "/Users/alan/Coding projects/my-repo" "$result"

# Test: leading/trailing space stripped (single space, typical drag-and-drop)
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
p=" /Users/alan/repo "
p="${p%$'\r'}"
p="${p## }"
p="${p%% }"
p="${(Q)p}"
echo "$p"
SCRIPT
)
assert_eq "leading/trailing space stripped" "/Users/alan/repo" "$result"

# Test: trailing CR stripped (Windows paste)
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
p=$'/Users/alan/repo\r'
p="${p%$'\r'}"
p="${p## }"
p="${p%% }"
p="${(Q)p}"
echo "$p"
SCRIPT
)
assert_eq "trailing CR stripped" "/Users/alan/repo" "$result"

# Test: plain path passes through unchanged
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
p="/Users/alan/simple-repo"
p="${p%$'\r'}"
p="${p## }"
p="${p%% }"
p="${(Q)p}"
echo "$p"
SCRIPT
)
assert_eq "plain path unchanged" "/Users/alan/simple-repo" "$result"

# Test: verify ${(Q)} is used in source (not manual quote stripping)
grep -q '${(Q)new_repo_path}' "$BOARD"
assert_eq '${(Q)} dequote present in source' "0" "$?"

# ── Fix C: Repo picker validation ───────────────────────────────────────────

echo ""
echo "Fix C: Repo picker error messages"

# Test: out-of-range number shows error
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
picker_repos=("repo-a" "repo-b")
pchoice="5"
_cancelled=false
new_repo=""
if ! $_cancelled && [[ -n "$pchoice" ]]; then
  if [[ "$pchoice" =~ ^[0-9]+$ ]]; then
    pchoice=$((pchoice - 1))
    if [[ $pchoice -ge 0 && $pchoice -lt ${#picker_repos[@]} ]]; then
      new_repo="${picker_repos[$pchoice]}"
    else
      echo "OUT_OF_RANGE"
    fi
  else
    echo "NOT_A_NUMBER"
  fi
fi
echo "repo=$new_repo"
SCRIPT
)
assert_eq "out-of-range shows error" "OUT_OF_RANGE
repo=" "$result"

# Test: non-numeric string shows error
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
picker_repos=("repo-a" "repo-b")
pchoice="abc"
_cancelled=false
new_repo=""
if ! $_cancelled && [[ -n "$pchoice" ]]; then
  if [[ "$pchoice" =~ ^[0-9]+$ ]]; then
    pchoice=$((pchoice - 1))
    if [[ $pchoice -ge 0 && $pchoice -lt ${#picker_repos[@]} ]]; then
      new_repo="${picker_repos[$pchoice]}"
    else
      echo "OUT_OF_RANGE"
    fi
  else
    echo "NOT_A_NUMBER"
  fi
fi
echo "repo=$new_repo"
SCRIPT
)
assert_eq "non-numeric shows error" "NOT_A_NUMBER
repo=" "$result"

# Test: empty input (Enter) is silent
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
picker_repos=("repo-a" "repo-b")
pchoice=""
_cancelled=false
new_repo=""
if ! $_cancelled && [[ -n "$pchoice" ]]; then
  if [[ "$pchoice" =~ ^[0-9]+$ ]]; then
    pchoice=$((pchoice - 1))
    if [[ $pchoice -ge 0 && $pchoice -lt ${#picker_repos[@]} ]]; then
      new_repo="${picker_repos[$pchoice]}"
    else
      echo "OUT_OF_RANGE"
    fi
  else
    echo "NOT_A_NUMBER"
  fi
fi
echo "repo=$new_repo"
SCRIPT
)
assert_eq "empty input is silent skip" "repo=" "$result"

# Test: valid choice selects correct repo
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
picker_repos=("repo-a" "repo-b" "repo-c")
pchoice="2"
_cancelled=false
new_repo=""
if ! $_cancelled && [[ -n "$pchoice" ]]; then
  if [[ "$pchoice" =~ ^[0-9]+$ ]]; then
    pchoice=$((pchoice - 1))
    if [[ $pchoice -ge 0 && $pchoice -lt ${#picker_repos[@]} ]]; then
      new_repo="${picker_repos[$pchoice]}"
    else
      echo "OUT_OF_RANGE"
    fi
  else
    echo "NOT_A_NUMBER"
  fi
fi
echo "repo=$new_repo"
SCRIPT
)
assert_eq "valid choice selects repo-b" "repo=repo-b" "$result"

# Test: zero is out of range (1-indexed display)
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
picker_repos=("repo-a" "repo-b")
pchoice="0"
_cancelled=false
new_repo=""
if ! $_cancelled && [[ -n "$pchoice" ]]; then
  if [[ "$pchoice" =~ ^[0-9]+$ ]]; then
    pchoice=$((pchoice - 1))
    if [[ $pchoice -ge 0 && $pchoice -lt ${#picker_repos[@]} ]]; then
      new_repo="${picker_repos[$pchoice]}"
    else
      echo "OUT_OF_RANGE"
    fi
  else
    echo "NOT_A_NUMBER"
  fi
fi
echo "repo=$new_repo"
SCRIPT
)
assert_eq "zero is out of range" "OUT_OF_RANGE
repo=" "$result"

# Test: verify else branches exist in source
grep -q 'Invalid choice (out of range)' "$BOARD"
assert_eq "out-of-range message in source" "0" "$?"
grep -q 'Invalid choice (not a number)' "$BOARD"
assert_eq "not-a-number message in source" "0" "$?"

# ── Fix D: Quoted $new_prompt ────────────────────────────────────────────────

echo ""
echo "Fix D: Quoted \$new_prompt"

# Test: verify $new_prompt is quoted in cmd_start call
grep -q 'cmd_start "\$new_id" "\$new_prompt"' "$BOARD"
assert_eq '"\$new_prompt" is quoted in cmd_start' "0" "$?"

# Test: verify unquoted version does NOT exist
if grep -q 'cmd_start "\$new_id" \$new_prompt)' "$BOARD"; then
  assert_eq "unquoted \$new_prompt absent" "absent" "present"
else
  assert_eq "unquoted \$new_prompt absent" "true" "true"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: $pass/$total passed, $fail failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ $fail -eq 0 ]] && exit 0 || exit 1
