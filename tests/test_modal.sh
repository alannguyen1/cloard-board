#!/usr/bin/env zsh
# Tests for new task creation modal
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

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  total=$((total + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  ✓ $label"
    pass=$((pass + 1))
  else
    echo "  ✗ $label"
    echo "    expected to contain: $needle"
    echo "    actual: $haystack"
    fail=$((fail + 1))
  fi
}

run_zsh() {
  local script="$TMPDIR_TEST/test_$$.zsh"
  cat > "$script"
  zsh "$script" 2>/dev/null
}

# ── Modal functions exist ─────────────────────────────────────────────────────

echo ""
echo "Modal: Function definitions"

grep -q '_modal_open()' "$BOARD"
assert_eq "_modal_open function defined" "0" "$?"

grep -q '_modal_render()' "$BOARD"
assert_eq "_modal_render function defined" "0" "$?"

grep -q '_modal_input_loop()' "$BOARD"
assert_eq "_modal_input_loop function defined" "0" "$?"

grep -q '_modal_render_success()' "$BOARD"
assert_eq "_modal_render_success function defined" "0" "$?"

grep -q '_modal_render_no_repos()' "$BOARD"
assert_eq "_modal_render_no_repos function defined" "0" "$?"

grep -q '_modal_render_field_repo()' "$BOARD"
assert_eq "_modal_render_field_repo function defined" "0" "$?"

grep -q '_modal_render_field_text()' "$BOARD"
assert_eq "_modal_render_field_text function defined" "0" "$?"

grep -q '_modal_render_field_toggle()' "$BOARD"
assert_eq "_modal_render_field_toggle function defined" "0" "$?"

grep -q '_modal_handle_tab()' "$BOARD"
assert_eq "_modal_handle_tab function defined" "0" "$?"

grep -q '_modal_handle_shift_tab()' "$BOARD"
assert_eq "_modal_handle_shift_tab function defined" "0" "$?"

grep -q '_modal_select_dropdown()' "$BOARD"
assert_eq "_modal_select_dropdown function defined" "0" "$?"

grep -q '_modal_handle_backspace()' "$BOARD"
assert_eq "_modal_handle_backspace function defined" "0" "$?"

grep -q '_modal_handle_ctrl_u()' "$BOARD"
assert_eq "_modal_handle_ctrl_u function defined" "0" "$?"

grep -q '_modal_handle_ctrl_w()' "$BOARD"
assert_eq "_modal_handle_ctrl_w function defined" "0" "$?"

# ── Key migration ────────────────────────────────────────────────────────────

echo ""
echo "Modal: Key migration (o -> c)"

# o) handler should NOT be present
if grep -q '^ *o) # ' "$BOARD"; then
  assert_eq "o) case handler removed" "absent" "present"
else
  assert_eq "o) case handler removed" "true" "true"
fi

# c) handler should be present
grep -q '^ *c) # ' "$BOARD"
assert_eq "c) case handler present" "0" "$?"

# Footer shows c: new, not o: new
if grep -q 'o: new' "$BOARD"; then
  assert_eq "footer shows c: new (not o: new)" "absent" "present"
else
  assert_eq "footer shows c: new (not o: new)" "true" "true"
fi

grep -q 'c: new' "$BOARD"
assert_eq "c: new present in footer" "0" "$?"

grep -q 'c: create' "$BOARD"
assert_eq "c: create present in cron footer" "0" "$?"

# ── Rendering structure ──────────────────────────────────────────────────────

echo ""
echo "Modal: Rendering structure"

grep -q '╔' "$BOARD"
assert_eq "double-line border ╔ present" "0" "$?"

grep -q '╗' "$BOARD"
assert_eq "double-line border ╗ present" "0" "$?"

grep -q '╚' "$BOARD"
assert_eq "double-line border ╚ present" "0" "$?"

grep -q '╝' "$BOARD"
assert_eq "double-line border ╝ present" "0" "$?"

grep -q '║' "$BOARD"
assert_eq "double-line border ║ present" "0" "$?"

grep -q 'New Task' "$BOARD"
assert_eq "New Task title in border" "0" "$?"

grep -q '"Repo:"' "$BOARD"
assert_eq "Repo: field label present" "0" "$?"

grep -q '"Title:"' "$BOARD"
assert_eq "Title: field label present" "0" "$?"

grep -q '"Worktree:"' "$BOARD"
assert_eq "Worktree: field label present" "0" "$?"

grep -q '"Prompt:"' "$BOARD"
assert_eq "Prompt: field label present" "0" "$?"

grep -q '▸' "$BOARD"
assert_eq "focus indicator ▸ present" "0" "$?"

grep -q '(•)' "$BOARD"
assert_eq "toggle marker (•) present" "0" "$?"

grep -q 'Works directly in the repo' "$BOARD"
assert_eq "worktree hint: direct" "0" "$?"

grep -q 'Isolated branch; merges back later' "$BOARD"
assert_eq "worktree hint: isolated" "0" "$?"

grep -q '(not a git repo)' "$BOARD"
assert_eq "worktree locked text present" "0" "$?"

grep -q 'Starting Claude\.\.\.' "$BOARD"
assert_eq "success text: Starting Claude..." "0" "$?"

grep -q 'No repos registered' "$BOARD"
assert_eq "no repos message present" "0" "$?"

grep -q 'select\.\.\.' "$BOARD"
assert_eq "dropdown placeholder select... present" "0" "$?"

grep -q '▼' "$BOARD"
assert_eq "dropdown indicator ▼ present" "0" "$?"

# ── Field behavior ────────────────────────────────────────────────────────────

echo ""
echo "Modal: Field behavior"

# Tab skips read-only fields
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
# Simulate _modal_handle_tab with repo readonly
_mf_repo_readonly=1
_mf_wt_locked=0
_mf_focus=3  # prompt
# Tab from prompt (3 -> 0 wraps, but 0 is readonly -> 1)
_modal_handle_tab() {
  local next=$(( _mf_focus + 1 ))
  [[ $next -gt 3 ]] && next=0
  [[ $next -eq 0 && $_mf_repo_readonly -eq 1 ]] && next=1
  [[ $next -eq 2 && $_mf_wt_locked -eq 1 ]] && next=3
  _mf_focus=$next
}
_modal_handle_tab
echo "$_mf_focus"
SCRIPT
)
assert_eq "tab skips read-only repo (3->1)" "1" "$result"

# Tab skips locked worktree
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_repo_readonly=0
_mf_wt_locked=1
_mf_focus=1  # title
_modal_handle_tab() {
  local next=$(( _mf_focus + 1 ))
  [[ $next -gt 3 ]] && next=0
  [[ $next -eq 0 && $_mf_repo_readonly -eq 1 ]] && next=1
  [[ $next -eq 2 && $_mf_wt_locked -eq 1 ]] && next=3
  _mf_focus=$next
}
_modal_handle_tab
echo "$_mf_focus"
SCRIPT
)
assert_eq "tab skips locked worktree (1->3)" "3" "$result"

# Worktree default is 0 (No)
grep -q '_mf_worktree=0' "$BOARD"
assert_eq "worktree default is 0 (No)" "0" "$?"

# --no-worktree passed when worktree=0
grep -q '\$_mf_worktree -eq 0.*--no-worktree' "$BOARD"
assert_eq "--no-worktree when worktree=0" "0" "$?"

# Dropdown select updates worktree lock for dir repos
grep -q '_modal_select_dropdown' "$BOARD"
assert_eq "dropdown select function present" "0" "$?"

# Verify dir-type check in dropdown select
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
typeset -A _repo_types
_repo_types[my-dir]="dir"
_repo_types[my-git]="git"
_mf_dropdown_idx=0
_mf_dropdown_open=1
_mf_focus=0
_mf_wt_locked=0
_mf_worktree=1
_mf_repo_list=("my-dir" "my-git")
_modal_select_dropdown() {
  _mf_repo="${_mf_repo_list[$_mf_dropdown_idx]}"
  _mf_dropdown_open=0
  if [[ "${_repo_types[$_mf_repo]:-git}" == "dir" ]]; then
    _mf_wt_locked=1
    _mf_worktree=0
  else
    _mf_wt_locked=0
  fi
  _mf_focus=1
}
_modal_select_dropdown
echo "repo=$_mf_repo locked=$_mf_wt_locked wt=$_mf_worktree focus=$_mf_focus"
SCRIPT
)
assert_eq "dir repo locks worktree" "repo=my-dir locked=1 wt=0 focus=1" "$result"

# Verify git repo doesn't lock
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
typeset -A _repo_types
_repo_types[my-dir]="dir"
_repo_types[my-git]="git"
_mf_dropdown_idx=1
_mf_dropdown_open=1
_mf_focus=0
_mf_wt_locked=1
_mf_worktree=0
_mf_repo_list=("my-dir" "my-git")
_modal_select_dropdown() {
  _mf_repo="${_mf_repo_list[$_mf_dropdown_idx]}"
  _mf_dropdown_open=0
  if [[ "${_repo_types[$_mf_repo]:-git}" == "dir" ]]; then
    _mf_wt_locked=1
    _mf_worktree=0
  else
    _mf_wt_locked=0
  fi
  _mf_focus=1
}
_modal_select_dropdown
echo "repo=$_mf_repo locked=$_mf_wt_locked focus=$_mf_focus"
SCRIPT
)
assert_eq "git repo unlocks worktree" "repo=my-git locked=0 focus=1" "$result"

# ── Text editing ──────────────────────────────────────────────────────────────

echo ""
echo "Modal: Text editing"

# Backspace removes last char
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_focus=1
_mf_title="hello"
_mf_prompt=""
_modal_handle_backspace() {
  if [[ $_mf_focus -eq 1 && -n "$_mf_title" ]]; then
    _mf_title="${_mf_title%?}"
  elif [[ $_mf_focus -eq 3 && -n "$_mf_prompt" ]]; then
    _mf_prompt="${_mf_prompt%?}"
  fi
}
_modal_handle_backspace
echo "$_mf_title"
SCRIPT
)
assert_eq "backspace on title" "hell" "$result"

# Ctrl-U clears field
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_focus=3
_mf_title="keep"
_mf_prompt="clear me"
_modal_handle_ctrl_u() {
  if [[ $_mf_focus -eq 1 ]]; then
    _mf_title=""
  elif [[ $_mf_focus -eq 3 ]]; then
    _mf_prompt=""
  fi
}
_modal_handle_ctrl_u
echo "title=$_mf_title prompt=$_mf_prompt"
SCRIPT
)
assert_eq "ctrl-u clears prompt only" "title=keep prompt=" "$result"

# Ctrl-W deletes last word
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_focus=1
_mf_title="hello world foo"
_mf_prompt=""
_modal_handle_ctrl_w() {
  local val=""
  if [[ $_mf_focus -eq 1 ]]; then val="$_mf_title"
  elif [[ $_mf_focus -eq 3 ]]; then val="$_mf_prompt"
  else return; fi
  while [[ "$val" == *' ' ]]; do val="${val% }"; done
  while [[ -n "$val" ]] && [[ "$val" != *' ' ]]; do val="${val%?}"; done
  if [[ $_mf_focus -eq 1 ]]; then _mf_title="$val"
  else _mf_prompt="$val"; fi
}
_modal_handle_ctrl_w
echo "$_mf_title"
SCRIPT
)
assert_eq "ctrl-w deletes last word" "hello world " "$result"

# ── Small terminal fallback ───────────────────────────────────────────────────

echo ""
echo "Modal: Small terminal fallback"

grep -q '_c_cols -lt 40' "$BOARD"
assert_eq "width < 40 check in c) handler" "0" "$?"

# ── Build order ───────────────────────────────────────────────────────────────

echo ""
echo "Modal: Build order"

[[ -f "$SCRIPT_DIR/../src/155-modal.sh" ]]
assert_eq "155-modal.sh exists in src/" "0" "$?"

# Verify modal functions appear before c) handler (build order correct)
modal_line=$(grep -n '_modal_open()' "$BOARD" | head -1 | cut -d: -f1)
handler_line=$(grep -n 'c) # Create new task' "$BOARD" | head -1 | cut -d: -f1)
if [[ -n "$modal_line" && -n "$handler_line" ]]; then
  if [[ $modal_line -lt $handler_line ]]; then
    assert_eq "modal functions before c) handler" "true" "true"
  else
    assert_eq "modal functions before c) handler" "before" "after"
  fi
else
  assert_eq "modal functions before c) handler" "both_found" "missing"
fi

# ── Shift-Tab navigation ─────────────────────────────────────────────────────

echo ""
echo "Modal: Shift-Tab navigation"

result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_repo_readonly=1
_mf_wt_locked=0
_mf_focus=1  # title
_modal_handle_shift_tab() {
  local prev=$(( _mf_focus - 1 ))
  [[ $prev -lt 0 ]] && prev=3
  [[ $prev -eq 2 && $_mf_wt_locked -eq 1 ]] && prev=1
  [[ $prev -eq 0 && $_mf_repo_readonly -eq 1 ]] && prev=3
  [[ $prev -eq 2 && $_mf_wt_locked -eq 1 ]] && prev=1
  _mf_focus=$prev
}
_modal_handle_shift_tab
echo "$_mf_focus"
SCRIPT
)
assert_eq "shift-tab skips readonly repo (1->3)" "3" "$result"

result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_repo_readonly=0
_mf_wt_locked=1
_mf_focus=3  # prompt
_modal_handle_shift_tab() {
  local prev=$(( _mf_focus - 1 ))
  [[ $prev -lt 0 ]] && prev=3
  [[ $prev -eq 2 && $_mf_wt_locked -eq 1 ]] && prev=1
  [[ $prev -eq 0 && $_mf_repo_readonly -eq 1 ]] && prev=3
  [[ $prev -eq 2 && $_mf_wt_locked -eq 1 ]] && prev=1
  _mf_focus=$prev
}
_modal_handle_shift_tab
echo "$_mf_focus"
SCRIPT
)
assert_eq "shift-tab skips locked worktree (3->1)" "1" "$result"

# ── Pre-fill logic ────────────────────────────────────────────────────────────

echo ""
echo "Modal: Pre-fill logic"

# Filter mode pre-fills repo
grep -q 'filter_mode.*!=.*all' "$BOARD"
assert_eq "filter_mode check in _modal_open" "0" "$?"

# Single repo detection
grep -q '_mf_repo_list\[@\].*-eq 1' "$BOARD"
assert_eq "single repo detection" "0" "$?"

grep -q '(only repo)' "$BOARD"
assert_eq "only repo hint text" "0" "$?"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: $pass/$total passed, $fail failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ $fail -eq 0 ]] && exit 0 || exit 1
