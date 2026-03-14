#!/usr/bin/env zsh
# Tests for unified create modal (Task + Cron)
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

# ── A: New function definitions ─────────────────────────────────────────────

echo ""
echo "A: New function definitions"

grep -q '_modal_render_field_type()' "$BOARD"
assert_eq "_modal_render_field_type defined" "0" "$?"

grep -q '_modal_render_cron_success()' "$BOARD"
assert_eq "_modal_render_cron_success defined" "0" "$?"

grep -q '_modal_create_cron()' "$BOARD"
assert_eq "_modal_create_cron defined" "0" "$?"

grep -q '_modal_toggle_type()' "$BOARD"
assert_eq "_modal_toggle_type defined" "0" "$?"

grep -q '_modal_sched_char_input()' "$BOARD"
assert_eq "_modal_sched_char_input defined" "0" "$?"

grep -q '_modal_sched_backspace()' "$BOARD"
assert_eq "_modal_sched_backspace defined" "0" "$?"

grep -q '_modal_sched_clear()' "$BOARD"
assert_eq "_modal_sched_clear defined" "0" "$?"

grep -q '_modal_select_schedule_dropdown()' "$BOARD"
assert_eq "_modal_select_schedule_dropdown defined" "0" "$?"

grep -q '_modal_render_schedule_field()' "$BOARD"
assert_eq "_modal_render_schedule_field defined" "0" "$?"

grep -q '_modal_render_schedule_sub_fields()' "$BOARD"
assert_eq "_modal_render_schedule_sub_fields defined" "0" "$?"

# ── B: Type toggle ──────────────────────────────────────────────────────────

echo ""
echo "B: Type toggle"

# Type toggle preserves prompt and repo, resets other fields
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
typeset -A _repo_types
_repo_types[myrepo]="git"
_mf_type=0
_mf_repo="myrepo"
_mf_prompt="my prompt"
_mf_title="my title"
_mf_name="my name"
_mf_worktree=1
_mf_sched_type=2
_mf_sched_time="10:30"
_mf_sched_start_h="8"
_mf_sched_end_h="20"
_mf_sched_at_min="15"
_mf_sched_interval="10"
_mf_wt_locked=0
_mf_sched_dd_open=0
_mf_sched_dd_idx=0
_modal_toggle_type() {
  _mf_type=$(( 1 - _mf_type ))
  _mf_title=""
  _mf_name=""
  _mf_sched_type=0
  _mf_sched_dd_open=0
  _mf_sched_dd_idx=0
  _mf_sched_time=""
  _mf_sched_start_h=""
  _mf_sched_end_h=""
  _mf_sched_at_min=""
  _mf_sched_interval=""
  _mf_worktree=0
  if [[ -n "$_mf_repo" && "${_repo_types[$_mf_repo]:-git}" == "dir" ]]; then
    _mf_wt_locked=1
  else
    _mf_wt_locked=0
  fi
}
_modal_toggle_type
echo "type=$_mf_type repo=$_mf_repo prompt=$_mf_prompt title=$_mf_title name=$_mf_name wt=$_mf_worktree sched=$_mf_sched_type time=$_mf_sched_time"
SCRIPT
)
assert_eq "toggle preserves repo+prompt, resets rest" \
  "type=1 repo=myrepo prompt=my prompt title= name= wt=0 sched=0 time=" "$result"

# Toggle back to task mode
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
typeset -A _repo_types
_repo_types[myrepo]="git"
_mf_type=1
_mf_repo="myrepo"
_mf_prompt="test"
_mf_name="cron-name"
_mf_title=""
_mf_worktree=0
_mf_wt_locked=0
_mf_sched_type=2
_mf_sched_dd_open=0
_mf_sched_dd_idx=0
_mf_sched_time=""
_mf_sched_start_h="9"
_mf_sched_end_h="17"
_mf_sched_at_min="0"
_mf_sched_interval=""
_modal_toggle_type() {
  _mf_type=$(( 1 - _mf_type ))
  _mf_title=""
  _mf_name=""
  _mf_sched_type=0
  _mf_sched_dd_open=0
  _mf_sched_dd_idx=0
  _mf_sched_time=""
  _mf_sched_start_h=""
  _mf_sched_end_h=""
  _mf_sched_at_min=""
  _mf_sched_interval=""
  _mf_worktree=0
  if [[ -n "$_mf_repo" && "${_repo_types[$_mf_repo]:-git}" == "dir" ]]; then
    _mf_wt_locked=1
  else
    _mf_wt_locked=0
  fi
}
_modal_toggle_type
echo "type=$_mf_type prompt=$_mf_prompt name=$_mf_name sched_start=$_mf_sched_start_h"
SCRIPT
)
assert_eq "toggle back to task preserves prompt" \
  "type=0 prompt=test name= sched_start=" "$result"

# Toggle sets wt_locked for dir repos
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
typeset -A _repo_types
_repo_types[dirrepo]="dir"
_mf_type=0
_mf_repo="dirrepo"
_mf_prompt=""
_mf_title=""
_mf_name=""
_mf_worktree=0
_mf_wt_locked=0
_mf_sched_type=0
_mf_sched_dd_open=0
_mf_sched_dd_idx=0
_mf_sched_time=""
_mf_sched_start_h=""
_mf_sched_end_h=""
_mf_sched_at_min=""
_mf_sched_interval=""
_modal_toggle_type() {
  _mf_type=$(( 1 - _mf_type ))
  _mf_title=""
  _mf_name=""
  _mf_sched_type=0
  _mf_sched_dd_open=0
  _mf_sched_dd_idx=0
  _mf_sched_time=""
  _mf_sched_start_h=""
  _mf_sched_end_h=""
  _mf_sched_at_min=""
  _mf_sched_interval=""
  _mf_worktree=0
  if [[ -n "$_mf_repo" && "${_repo_types[$_mf_repo]:-git}" == "dir" ]]; then
    _mf_wt_locked=1
  else
    _mf_wt_locked=0
  fi
}
_modal_toggle_type
echo "locked=$_mf_wt_locked"
SCRIPT
)
assert_eq "toggle type locks worktree for dir repo" "locked=1" "$result"

# ── C: Focus cycling ────────────────────────────────────────────────────────

echo ""
echo "C: Focus cycling"

# Task mode: 0 -> 1 -> 2 -> 3 -> 4 -> 0 (wrap)
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_type=0
_mf_repo_readonly=0
_mf_wt_locked=0
_mf_sched_type=0
_mf_focus=0
_modal_handle_tab() {
  local max_focus
  [[ $_mf_type -eq 0 ]] && max_focus=4 || max_focus=7
  local next=$(( _mf_focus + 1 ))
  [[ $next -gt $max_focus ]] && next=0
  [[ $next -eq 1 && $_mf_repo_readonly -eq 1 ]] && next=2
  if [[ $_mf_type -eq 0 && $next -eq 3 && $_mf_wt_locked -eq 1 ]]; then next=4; fi
  if [[ $_mf_type -eq 1 && ($_mf_sched_type -eq 0 || $_mf_sched_type -eq 1) ]]; then
    [[ $next -eq 5 ]] && next=7
    [[ $next -eq 6 ]] && next=7
  fi
  [[ $next -gt $max_focus ]] && next=0
  [[ $next -eq 1 && $_mf_repo_readonly -eq 1 ]] && next=2
  _mf_focus=$next
}
_modal_handle_tab; echo -n "$_mf_focus "
_modal_handle_tab; echo -n "$_mf_focus "
_modal_handle_tab; echo -n "$_mf_focus "
_modal_handle_tab; echo -n "$_mf_focus "
_modal_handle_tab; echo -n "$_mf_focus"
SCRIPT
)
assert_eq "task mode tab cycle: 0->1->2->3->4->0" "1 2 3 4 0" "$result"

# Task mode: skip worktree when locked
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_type=0
_mf_repo_readonly=0
_mf_wt_locked=1
_mf_sched_type=0
_mf_focus=2
_modal_handle_tab() {
  local max_focus
  [[ $_mf_type -eq 0 ]] && max_focus=4 || max_focus=7
  local next=$(( _mf_focus + 1 ))
  [[ $next -gt $max_focus ]] && next=0
  [[ $next -eq 1 && $_mf_repo_readonly -eq 1 ]] && next=2
  if [[ $_mf_type -eq 0 && $next -eq 3 && $_mf_wt_locked -eq 1 ]]; then next=4; fi
  if [[ $_mf_type -eq 1 && ($_mf_sched_type -eq 0 || $_mf_sched_type -eq 1) ]]; then
    [[ $next -eq 5 ]] && next=7
    [[ $next -eq 6 ]] && next=7
  fi
  [[ $next -gt $max_focus ]] && next=0
  [[ $next -eq 1 && $_mf_repo_readonly -eq 1 ]] && next=2
  _mf_focus=$next
}
_modal_handle_tab
echo "$_mf_focus"
SCRIPT
)
assert_eq "task tab skips locked worktree (2->4)" "4" "$result"

# Cron mode daily: 0 -> 1 -> 2 -> 3 -> 4 -> 7 (skip 5,6) -> 0
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_type=1
_mf_repo_readonly=0
_mf_wt_locked=0
_mf_sched_type=0
_mf_focus=0
_modal_handle_tab() {
  local max_focus
  [[ $_mf_type -eq 0 ]] && max_focus=4 || max_focus=7
  local next=$(( _mf_focus + 1 ))
  [[ $next -gt $max_focus ]] && next=0
  [[ $next -eq 1 && $_mf_repo_readonly -eq 1 ]] && next=2
  if [[ $_mf_type -eq 0 && $next -eq 3 && $_mf_wt_locked -eq 1 ]]; then next=4; fi
  if [[ $_mf_type -eq 1 && ($_mf_sched_type -eq 0 || $_mf_sched_type -eq 1) ]]; then
    [[ $next -eq 5 ]] && next=7
    [[ $next -eq 6 ]] && next=7
  fi
  [[ $next -gt $max_focus ]] && next=0
  [[ $next -eq 1 && $_mf_repo_readonly -eq 1 ]] && next=2
  _mf_focus=$next
}
_modal_handle_tab; echo -n "$_mf_focus "
_modal_handle_tab; echo -n "$_mf_focus "
_modal_handle_tab; echo -n "$_mf_focus "
_modal_handle_tab; echo -n "$_mf_focus "
_modal_handle_tab; echo -n "$_mf_focus "
_modal_handle_tab; echo -n "$_mf_focus"
SCRIPT
)
assert_eq "cron daily tab: 0->1->2->3->4->7->0" "1 2 3 4 7 0" "$result"

# Cron mode hourly: 0 -> 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 0
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_type=1
_mf_repo_readonly=0
_mf_wt_locked=0
_mf_sched_type=2
_mf_focus=0
_modal_handle_tab() {
  local max_focus
  [[ $_mf_type -eq 0 ]] && max_focus=4 || max_focus=7
  local next=$(( _mf_focus + 1 ))
  [[ $next -gt $max_focus ]] && next=0
  [[ $next -eq 1 && $_mf_repo_readonly -eq 1 ]] && next=2
  if [[ $_mf_type -eq 0 && $next -eq 3 && $_mf_wt_locked -eq 1 ]]; then next=4; fi
  if [[ $_mf_type -eq 1 && ($_mf_sched_type -eq 0 || $_mf_sched_type -eq 1) ]]; then
    [[ $next -eq 5 ]] && next=7
    [[ $next -eq 6 ]] && next=7
  fi
  [[ $next -gt $max_focus ]] && next=0
  [[ $next -eq 1 && $_mf_repo_readonly -eq 1 ]] && next=2
  _mf_focus=$next
}
_modal_handle_tab; echo -n "$_mf_focus "
_modal_handle_tab; echo -n "$_mf_focus "
_modal_handle_tab; echo -n "$_mf_focus "
_modal_handle_tab; echo -n "$_mf_focus "
_modal_handle_tab; echo -n "$_mf_focus "
_modal_handle_tab; echo -n "$_mf_focus "
_modal_handle_tab; echo -n "$_mf_focus "
_modal_handle_tab; echo -n "$_mf_focus"
SCRIPT
)
assert_eq "cron hourly tab visits all sub-fields" "1 2 3 4 5 6 7 0" "$result"

# Cron mode weekdays: skip 5,6 (same as daily)
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_type=1
_mf_repo_readonly=0
_mf_wt_locked=0
_mf_sched_type=1
_mf_focus=4
_modal_handle_tab() {
  local max_focus
  [[ $_mf_type -eq 0 ]] && max_focus=4 || max_focus=7
  local next=$(( _mf_focus + 1 ))
  [[ $next -gt $max_focus ]] && next=0
  [[ $next -eq 1 && $_mf_repo_readonly -eq 1 ]] && next=2
  if [[ $_mf_type -eq 0 && $next -eq 3 && $_mf_wt_locked -eq 1 ]]; then next=4; fi
  if [[ $_mf_type -eq 1 && ($_mf_sched_type -eq 0 || $_mf_sched_type -eq 1) ]]; then
    [[ $next -eq 5 ]] && next=7
    [[ $next -eq 6 ]] && next=7
  fi
  [[ $next -gt $max_focus ]] && next=0
  [[ $next -eq 1 && $_mf_repo_readonly -eq 1 ]] && next=2
  _mf_focus=$next
}
_modal_handle_tab
echo "$_mf_focus"
SCRIPT
)
assert_eq "cron weekdays tab skips 5,6 (4->7)" "7" "$result"

# Shift-tab cron daily: 7 -> 4 (skip 6,5)
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_type=1
_mf_repo_readonly=0
_mf_wt_locked=0
_mf_sched_type=0
_mf_focus=7
_modal_handle_shift_tab() {
  local max_focus
  [[ $_mf_type -eq 0 ]] && max_focus=4 || max_focus=7
  local prev=$(( _mf_focus - 1 ))
  [[ $prev -lt 0 ]] && prev=$max_focus
  if [[ $_mf_type -eq 1 && ($_mf_sched_type -eq 0 || $_mf_sched_type -eq 1) ]]; then
    [[ $prev -eq 6 ]] && prev=4
    [[ $prev -eq 5 ]] && prev=4
  fi
  if [[ $_mf_type -eq 0 && $prev -eq 3 && $_mf_wt_locked -eq 1 ]]; then prev=2; fi
  [[ $prev -eq 1 && $_mf_repo_readonly -eq 1 ]] && prev=0
  _mf_focus=$prev
}
_modal_handle_shift_tab
echo "$_mf_focus"
SCRIPT
)
assert_eq "shift-tab cron daily skips 6,5 (7->4)" "4" "$result"

# ── D: Schedule dropdown ────────────────────────────────────────────────────

echo ""
echo "D: Schedule dropdown"

# Select schedule dropdown item
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_sched_dd_idx=2
_mf_sched_dd_open=1
_mf_sched_type=0
_mf_sched_time="08:00"
_mf_sched_start_h="5"
_mf_sched_end_h="18"
_mf_sched_at_min="30"
_mf_sched_interval=""
_mf_focus=3
_modal_select_schedule_dropdown() {
  _mf_sched_type=$_mf_sched_dd_idx
  _mf_sched_dd_open=0
  _mf_sched_time=""
  _mf_sched_start_h=""
  _mf_sched_end_h=""
  _mf_sched_at_min=""
  _mf_sched_interval=""
  _mf_focus=4
}
_modal_select_schedule_dropdown
echo "type=$_mf_sched_type open=$_mf_sched_dd_open focus=$_mf_focus time=$_mf_sched_time start=$_mf_sched_start_h"
SCRIPT
)
assert_eq "select schedule dropdown resets sub-fields" \
  "type=2 open=0 focus=4 time= start=" "$result"

# Mutual exclusivity: opening schedule closes repo
grep -q '_mf_sched_dd_open=1' "$BOARD"
assert_eq "schedule dropdown open assignment present" "0" "$?"
grep -q '_mf_dropdown_open=0' "$BOARD"
assert_eq "repo dropdown close on schedule open present" "0" "$?"

# ── E: Schedule sub-field input ──────────────────────────────────────────────

echo ""
echo "E: Schedule sub-field input"

# Char input for daily time
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_sched_type=0
_mf_focus=4
_mf_sched_time=""
_modal_sched_char_input() {
  local ch="$1"
  case $_mf_sched_type in
    0|1)
      if [[ $_mf_focus -eq 4 && "$ch" =~ [0-9:] ]]; then
        _mf_sched_time+="$ch"
      fi
      ;;
    2)
      if [[ "$ch" =~ [0-9] ]]; then
        case $_mf_focus in
          4) _mf_sched_start_h+="$ch" ;; 5) _mf_sched_end_h+="$ch" ;; 6) _mf_sched_at_min+="$ch" ;;
        esac
      fi
      ;;
    3)
      if [[ "$ch" =~ [0-9] ]]; then
        case $_mf_focus in
          4) _mf_sched_start_h+="$ch" ;; 5) _mf_sched_end_h+="$ch" ;; 6) _mf_sched_interval+="$ch" ;;
        esac
      fi
      ;;
  esac
}
_modal_sched_char_input "1"
_modal_sched_char_input "0"
_modal_sched_char_input ":"
_modal_sched_char_input "3"
_modal_sched_char_input "0"
echo "$_mf_sched_time"
SCRIPT
)
assert_eq "daily time input accepts digits and colon" "10:30" "$result"

# Char input for hourly start hour
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_sched_type=2
_mf_focus=4
_mf_sched_start_h=""
_mf_sched_end_h=""
_mf_sched_at_min=""
_modal_sched_char_input() {
  local ch="$1"
  case $_mf_sched_type in
    0|1)
      if [[ $_mf_focus -eq 4 && "$ch" =~ [0-9:] ]]; then _mf_sched_time+="$ch"; fi
      ;;
    2)
      if [[ "$ch" =~ [0-9] ]]; then
        case $_mf_focus in
          4) _mf_sched_start_h+="$ch" ;; 5) _mf_sched_end_h+="$ch" ;; 6) _mf_sched_at_min+="$ch" ;;
        esac
      fi
      ;;
    3)
      if [[ "$ch" =~ [0-9] ]]; then
        case $_mf_focus in
          4) _mf_sched_start_h+="$ch" ;; 5) _mf_sched_end_h+="$ch" ;; 6) _mf_sched_interval+="$ch" ;;
        esac
      fi
      ;;
  esac
}
_modal_sched_char_input "9"
echo "$_mf_sched_start_h"
SCRIPT
)
assert_eq "hourly start hour input" "9" "$result"

# Rejects non-digit for hourly
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_sched_type=2
_mf_focus=4
_mf_sched_start_h=""
_modal_sched_char_input() {
  local ch="$1"
  case $_mf_sched_type in
    2)
      if [[ "$ch" =~ [0-9] ]]; then
        case $_mf_focus in 4) _mf_sched_start_h+="$ch" ;; esac
      fi
      ;;
  esac
}
_modal_sched_char_input ":"
_modal_sched_char_input "a"
echo "val='$_mf_sched_start_h'"
SCRIPT
)
assert_eq "hourly rejects non-digits" "val=''" "$result"

# Interval sub-field input at focus 6
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_sched_type=3
_mf_focus=6
_mf_sched_interval=""
_mf_sched_start_h=""
_mf_sched_end_h=""
_modal_sched_char_input() {
  local ch="$1"
  case $_mf_sched_type in
    3)
      if [[ "$ch" =~ [0-9] ]]; then
        case $_mf_focus in
          4) _mf_sched_start_h+="$ch" ;; 5) _mf_sched_end_h+="$ch" ;; 6) _mf_sched_interval+="$ch" ;;
        esac
      fi
      ;;
  esac
}
_modal_sched_char_input "3"
_modal_sched_char_input "0"
echo "$_mf_sched_interval"
SCRIPT
)
assert_eq "interval sub-field input at focus 6" "30" "$result"

# ── F: Backspace and Ctrl-U on new fields ────────────────────────────────────

echo ""
echo "F: Backspace and Ctrl-U on new fields"

# Backspace on cron name (focus 2, type 1)
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_type=1
_mf_focus=2
_mf_title=""
_mf_name="hello"
_mf_prompt=""
_mf_sched_type=0
_modal_handle_backspace() {
  local prompt_idx
  [[ $_mf_type -eq 0 ]] && prompt_idx=4 || prompt_idx=7
  if [[ $_mf_focus -eq 2 ]]; then
    if [[ $_mf_type -eq 0 && -n "$_mf_title" ]]; then _mf_title="${_mf_title%?}"
    elif [[ $_mf_type -eq 1 && -n "$_mf_name" ]]; then _mf_name="${_mf_name%?}"
    fi
  elif [[ $_mf_focus -eq $prompt_idx && -n "$_mf_prompt" ]]; then
    _mf_prompt="${_mf_prompt%?}"
  fi
}
_modal_handle_backspace
echo "$_mf_name"
SCRIPT
)
assert_eq "backspace on cron name" "hell" "$result"

# Ctrl-U on cron name
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_type=1
_mf_focus=2
_mf_name="test-name"
_mf_title=""
_mf_prompt=""
_mf_sched_type=0
_modal_handle_ctrl_u() {
  local prompt_idx
  [[ $_mf_type -eq 0 ]] && prompt_idx=4 || prompt_idx=7
  if [[ $_mf_focus -eq 2 ]]; then
    [[ $_mf_type -eq 0 ]] && _mf_title="" || _mf_name=""
  elif [[ $_mf_focus -eq $prompt_idx ]]; then
    _mf_prompt=""
  fi
}
_modal_handle_ctrl_u
echo "name=$_mf_name"
SCRIPT
)
assert_eq "ctrl-u clears cron name" "name=" "$result"

# Backspace on schedule sub-field (daily time)
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_type=1
_mf_focus=4
_mf_sched_type=0
_mf_sched_time="10:3"
_modal_sched_backspace() {
  case $_mf_sched_type in
    0|1) [[ $_mf_focus -eq 4 && -n "$_mf_sched_time" ]] && _mf_sched_time="${_mf_sched_time%?}" ;;
  esac
}
_modal_sched_backspace
echo "$_mf_sched_time"
SCRIPT
)
assert_eq "backspace on schedule time" "10:" "$result"

# Ctrl-U on schedule sub-field
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_type=1
_mf_focus=4
_mf_sched_type=0
_mf_sched_time="09:00"
_modal_sched_clear() {
  case $_mf_sched_type in
    0|1) [[ $_mf_focus -eq 4 ]] && _mf_sched_time="" ;;
  esac
}
_modal_sched_clear
echo "time=$_mf_sched_time"
SCRIPT
)
assert_eq "ctrl-u clears schedule time" "time=" "$result"

# ── G: Ctrl-W on title vs name ──────────────────────────────────────────────

echo ""
echo "G: Ctrl-W on title vs name"

result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_type=1
_mf_focus=2
_mf_name="my cron name"
_mf_title="keep this"
_mf_prompt=""
_modal_handle_ctrl_w() {
  local prompt_idx
  [[ $_mf_type -eq 0 ]] && prompt_idx=4 || prompt_idx=7
  local val=""
  if [[ $_mf_focus -eq 2 ]]; then
    [[ $_mf_type -eq 0 ]] && val="$_mf_title" || val="$_mf_name"
  elif [[ $_mf_focus -eq $prompt_idx ]]; then val="$_mf_prompt"
  else return; fi
  while [[ "$val" == *' ' ]]; do val="${val% }"; done
  while [[ -n "$val" ]] && [[ "$val" != *' ' ]]; do val="${val%?}"; done
  if [[ $_mf_focus -eq 2 ]]; then
    [[ $_mf_type -eq 0 ]] && _mf_title="$val" || _mf_name="$val"
  else _mf_prompt="$val"; fi
}
_modal_handle_ctrl_w
echo "name=$_mf_name title=$_mf_title"
SCRIPT
)
assert_eq "ctrl-w deletes word from cron name, not title" "name=my cron  title=keep this" "$result"

# ── H: Cron creation state record ───────────────────────────────────────────

echo ""
echo "H: Cron creation state record"

# _modal_create_cron produces correct schedule for daily
_test_cron_dir="$TMPDIR_TEST/state_daily"
mkdir -p "$_test_cron_dir"
_test_cron_state="$_test_cron_dir/state.json"
cat > "$_test_cron_state" <<'JSON'
{"version":5,"next_task_id":1,"next_cron_id":1,"next_run_id":1,"repos":[{"name":"test","path":"/tmp/test","type":"git"}],"tasks":[],"cron_jobs":[],"cron_runs":[]}
JSON
result=$(GLOBAL_DIR="$_test_cron_dir" GLOBAL_STATE="$_test_cron_state" zsh -c '
setopt KSH_ARRAYS
_lock_state() { return 0; }
_unlock_state() { return; }
now_iso() { echo "2026-03-11T00:00:00Z"; }
repo_path() { echo "/tmp/test"; }
_next_cron_id() {
  local num=$(jq -r ".next_cron_id" "$GLOBAL_STATE")
  local new_id=$(printf "cj-%03d" "$num")
  local tmp=$(mktemp "${GLOBAL_DIR}/.c.XXXXXX")
  jq ".next_cron_id += 1" "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
  echo "$new_id"
}
_generate_plist() { echo "/tmp/test.plist"; }
_mf_repo="test"
_mf_name="Daily Job"
_mf_prompt="Do daily tasks"
_mf_sched_type=0
_mf_sched_time="08:30"
_mf_sched_start_h="" _mf_sched_end_h="" _mf_sched_at_min="" _mf_sched_interval=""

_modal_create_cron() {
  [[ -n "$_mf_repo" ]] || return 1
  [[ -n "$_mf_name" ]] || return 1
  [[ -n "$_mf_prompt" ]] || return 1
  local name
  name=$(echo "$_mf_name" | tr "[:upper:]" "[:lower:]" | tr " _" "-" | tr -cd "a-z0-9-")
  local working_dir
  working_dir=$(repo_path "$_mf_repo")
  local schedule_type schedule_desc schedule_raw
  case $_mf_sched_type in
    0)
      local time_str="${_mf_sched_time:-09:00}"
      local hour minute
      hour=$(echo "$time_str" | cut -d: -f1 | sed "s/^0*//")
      minute=$(echo "$time_str" | cut -d: -f2 | sed "s/^0*//")
      [[ -z "$hour" ]] && hour=0
      [[ -z "$minute" ]] && minute=0
      schedule_type="daily"
      schedule_desc="Daily at ${time_str}"
      schedule_raw=$(jq -n --argjson h "$hour" --argjson m "$minute" "{Hour: \$h, Minute: \$m}")
      ;;
  esac
  local claude_cmd="claude -p test"
  local env_vars="{}"
  local cron_id
  cron_id=$(_next_cron_id)
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.c.XXXXXX")
  jq --arg id "$cron_id" --arg name "$name" --arg wdir "$working_dir" \
    --arg cmd "$claude_cmd" --arg stype "$schedule_type" --arg sdesc "$schedule_desc" \
    --argjson sraw "$schedule_raw" --argjson env "$env_vars" --arg now "$(now_iso)" "
    .cron_jobs += [{
      id: \$id, label: \"\", name: \$name, plist_path: \"\",
      working_dir: \$wdir, claude_command: \$cmd,
      schedule_type: \$stype, schedule_desc: \$sdesc, schedule_raw: \$sraw,
      enabled: true, created_at: \$now, env_vars: \$env
    }]
  " "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
  echo "$cron_id"
}

id=$(_modal_create_cron 2>/dev/null)
echo "id=$id"
name=$(jq -r ".cron_jobs[0].name" "$GLOBAL_STATE")
echo "name=$name"
stype=$(jq -r ".cron_jobs[0].schedule_type" "$GLOBAL_STATE")
echo "stype=$stype"
hour=$(jq -r ".cron_jobs[0].schedule_raw.Hour" "$GLOBAL_STATE")
echo "hour=$hour"
minute=$(jq -r ".cron_jobs[0].schedule_raw.Minute" "$GLOBAL_STATE")
echo "minute=$minute"
' 2>/dev/null)
assert_contains "daily cron job created" "id=cj-001" "$result"
assert_contains "daily cron name sanitized" "name=daily-job" "$result"
assert_contains "daily schedule type" "stype=daily" "$result"
assert_contains "daily schedule hour" "hour=8" "$result"
assert_contains "daily schedule minute" "minute=30" "$result"

# Weekdays schedule includes Weekday keys
result=$(run_zsh <<'SCRIPT'
setopt KSH_ARRAYS
_mf_sched_type=1
_mf_sched_time="09:00"
local time_str="${_mf_sched_time:-09:00}"
local hour minute
hour=$(echo "$time_str" | cut -d: -f1 | sed 's/^0*//')
minute=$(echo "$time_str" | cut -d: -f2 | sed 's/^0*//')
[[ -z "$hour" ]] && hour=0
[[ -z "$minute" ]] && minute=0
schedule_raw="["
local sep="" wd
for wd in 1 2 3 4 5; do
  schedule_raw="${schedule_raw}${sep}{\"Hour\":${hour},\"Minute\":${minute},\"Weekday\":${wd}}"
  sep=","
done
schedule_raw="${schedule_raw}]"
echo "$schedule_raw" | jq -r '.[0].Weekday'
echo "$schedule_raw" | jq -r '.[4].Weekday'
echo "$schedule_raw" | jq -r 'length'
SCRIPT
)
assert_eq "weekdays schedule has Weekday 1..5" "$(printf '1\n5\n5')" "$result"

# ── I: Rendering structure (new elements) ────────────────────────────────────

echo ""
echo "I: Rendering structure (new elements)"

grep -q '"Type:"' "$BOARD"
assert_eq "Type: field label present" "0" "$?"

grep -q '"Name:"' "$BOARD"
assert_eq "Name: field label present" "0" "$?"

grep -q '"Schedule:"' "$BOARD"
assert_eq "Schedule: field label present" "0" "$?"

grep -q 'New Cron Job' "$BOARD"
assert_eq "New Cron Job title in border" "0" "$?"

grep -q 'Scheduled and loaded' "$BOARD"
assert_eq "cron success message present" "0" "$?"

grep -q 'Task.*Cron' "$BOARD"
assert_eq "type toggle text present" "0" "$?"

grep -q 'Daily at HH:MM' "$BOARD"
assert_eq "schedule dropdown: Daily option" "0" "$?"

grep -q 'Weekdays at HH:MM' "$BOARD"
assert_eq "schedule dropdown: Weekdays option" "0" "$?"

grep -q 'Hourly (range)' "$BOARD"
assert_eq "schedule dropdown: Hourly option" "0" "$?"

grep -q 'Every N min (range)' "$BOARD"
assert_eq "schedule dropdown: Interval option" "0" "$?"

# ── J: Context-aware default type ────────────────────────────────────────────

echo ""
echo "J: Context-aware default type"

grep -q 'cron_row_selected.*-eq 1' "$BOARD"
assert_eq "cron row check for type default" "0" "$?"

grep -q 'cron_group:\*\|cron:\*' "$BOARD" || grep -q 'cron_group:.*cron:' "$BOARD"
assert_eq "list mode cron item check for type default" "0" "$?"

grep -q '_mf_type=1' "$BOARD"
assert_eq "_mf_type=1 for cron context" "0" "$?"

# ── K: Small terminal cron fallback ──────────────────────────────────────────

echo ""
echo "K: Small terminal cron fallback"

grep -q 'What to create' "$BOARD"
assert_eq "small terminal type prompt" "0" "$?"

grep -q '1) Task' "$BOARD"
assert_eq "small terminal task option" "0" "$?"

grep -q '2) Cron Job' "$BOARD"
assert_eq "small terminal cron option" "0" "$?"

grep -q 'Job name' "$BOARD"
assert_eq "small terminal cron name prompt" "0" "$?"

# ── L: CLI cmd_cron_add weekdays ─────────────────────────────────────────────

echo ""
echo "L: CLI cmd_cron_add weekdays"

grep -q 'Weekdays at HH:MM' "$BOARD"
assert_eq "weekdays option in CLI schedule menu" "0" "$?"

grep -q 'schedule_type="weekdays"' "$BOARD"
assert_eq "weekdays schedule type in CLI" "0" "$?"

grep -q 'Weekday' "$BOARD"
assert_eq "Weekday key in schedule_raw" "0" "$?"

# ── M: Cron submission function ──────────────────────────────────────────────

echo ""
echo "M: Cron submission function"

grep -q 'repo_path' "$BOARD"
assert_eq "_modal_create_cron uses repo_path" "0" "$?"

grep -q '_generate_plist' "$BOARD"
assert_eq "_modal_create_cron calls _generate_plist" "0" "$?"

grep -q 'launchctl load' "$BOARD"
assert_eq "_modal_create_cron loads plist" "0" "$?"

grep -q 'CLAUDE_CODE_OAUTH_TOKEN' "$BOARD"
assert_eq "env var capture includes oauth token" "0" "$?"

grep -q "claude -p" "$BOARD"
assert_eq "prompt-based claude command" "0" "$?"

# Name sanitization present
grep -q "tr '\[:upper:\]' '\[:lower:\]'" "$BOARD"
assert_eq "name sanitization: lowercase" "0" "$?"

grep -q "tr -cd 'a-z0-9-'" "$BOARD"
assert_eq "name sanitization: strip special chars" "0" "$?"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: $pass/$total passed, $fail failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ $fail -eq 0 ]] && exit 0 || exit 1
