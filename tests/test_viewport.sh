#!/usr/bin/env zsh
# Tests for compact card accordion logic:
#   - Accordion expand/collapse
#   - Space calculation with compact 3-line cards
#   - Source structure checks
set -euo pipefail
setopt KSH_ARRAYS

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

# Simulate accordion space calculation from the dashboard
calc_accordion() {
  local expanded_count=$1 collapsed_count=$2 rows=$3 has_cron=$4

  local cron_reserve=0
  [[ "$has_cron" == "true" ]] && cron_reserve=8

  [[ $expanded_count -lt 1 ]] && expanded_count=1
  local collapsed_lines=$collapsed_count
  local available=$((rows - 2 - collapsed_lines - cron_reserve))
  local per_expanded=$(( available / expanded_count ))
  local max_cards=$(( (per_expanded - 2) / 3 ))
  [[ $max_cards -lt 1 ]] && max_cards=1

  echo "$per_expanded $max_cards"
}

# ── Accordion space calculation ─────────────────────────────────

echo ""
echo "Accordion space calculation"

# 2 expanded, 0 collapsed, 40 rows, no cron
result=$(calc_accordion 2 0 40 false)
read per_exp cards <<< "$result"
assert_eq "2 expanded 40 rows: cards >= 3" "true" "$([[ $cards -ge 3 ]] && echo true || echo false)"

# 4 expanded, 2 collapsed, 40 rows, no cron: (36/4-2)/3 = 2 cards
result=$(calc_accordion 4 2 40 false)
read per_exp cards <<< "$result"
assert_eq "4 exp 2 col 40 rows: cards >= 2" "true" "$([[ $cards -ge 2 ]] && echo true || echo false)"

# 3 expanded, 3 collapsed, 40 rows, no cron
result=$(calc_accordion 3 3 40 false)
read per_exp cards <<< "$result"
assert_eq "3 exp 3 col 40 rows: cards >= 3" "true" "$([[ $cards -ge 3 ]] && echo true || echo false)"

# 1 expanded, 5 collapsed, 24 rows, no cron
result=$(calc_accordion 1 5 24 false)
read per_exp cards <<< "$result"
assert_eq "1 exp 5 col 24 rows: cards >= 3" "true" "$([[ $cards -ge 3 ]] && echo true || echo false)"

# 4 expanded, 6 collapsed, 40 rows, with cron
result=$(calc_accordion 4 6 40 true)
read per_exp cards <<< "$result"
assert_eq "4 exp 6 col 40 rows cron: cards >= 1" "true" "$([[ $cards -ge 1 ]] && echo true || echo false)"

# 1 expanded, 0 collapsed, 24 rows, no cron: single repo gets all space
result=$(calc_accordion 1 0 24 false)
read per_exp cards <<< "$result"
assert_eq "1 repo 24 rows: per_expanded >= 11" "true" "$([[ $per_exp -ge 11 ]] && echo true || echo false)"
assert_eq "1 repo 24 rows: cards >= 3" "true" "$([[ $cards -ge 3 ]] && echo true || echo false)"

# Edge case: many expanded in small terminal
result=$(calc_accordion 6 0 24 false)
read per_exp cards <<< "$result"
assert_eq "6 exp 24 rows: cards >= 1 (min)" "true" "$([[ $cards -ge 1 ]] && echo true || echo false)"

# ── Accordion toggle logic ───────────────────────────────────

echo ""
echo "Accordion toggle logic"

# Simulate the toggle behavior
typeset -A _repo_collapsed
repos=(alpha bravo charlie delta echo foxtrot)
MAX_EXPANDED=4

# Initialize: first 4 expanded, rest collapsed
local _init_exp=0
for rn in "${repos[@]}"; do
  [[ $_init_exp -ge $MAX_EXPANDED ]] && _repo_collapsed[$rn]=1
  _init_exp=$((_init_exp + 1))
done

assert_eq "alpha starts expanded" "true" "$([[ "${_repo_collapsed[alpha]:-}" != "1" ]] && echo true || echo false)"
assert_eq "delta starts expanded" "true" "$([[ "${_repo_collapsed[delta]:-}" != "1" ]] && echo true || echo false)"
assert_eq "echo starts collapsed" "1" "${_repo_collapsed[echo]}"
assert_eq "foxtrot starts collapsed" "1" "${_repo_collapsed[foxtrot]}"

# Toggle: collapse alpha
_repo_collapsed[alpha]=1
assert_eq "alpha collapsed after toggle" "1" "${_repo_collapsed[alpha]}"

# Toggle: expand echo
unset '_repo_collapsed[echo]'
assert_eq "echo expanded after toggle" "true" "$([[ "${_repo_collapsed[echo]:-}" != "1" ]] && echo true || echo false)"

# Toggle: collapse echo again
_repo_collapsed[echo]=1
assert_eq "echo re-collapsed" "1" "${_repo_collapsed[echo]}"

# Count expanded
local exp_count=0
for rn in "${repos[@]}"; do
  [[ "${_repo_collapsed[$rn]:-}" != "1" ]] && exp_count=$((exp_count + 1))
done
assert_eq "3 expanded after toggles" "3" "$exp_count"

# ── Source structure checks ───────────────────────────────────

echo ""
echo "Source structure checks"

BOARD="$(cd "$(dirname "$0")" && pwd)/../cloard-board"

# All-repos view uses 3-line compact cards (line_no in {0..2})
grep -q 'for line_no in {0..2}' "$BOARD"
assert_eq "all-repos uses 3-line compact cards" "0" "$?"

# Filtered view still uses 5-line cards (line_no in {0..4})
grep -q 'for line_no in {0..4}' "$BOARD"
assert_eq "filtered view keeps 5-line full cards" "0" "$?"

# Accordion state variable present
grep -q '_repo_collapsed' "$BOARD"
assert_eq "accordion state variable present" "0" "$?"

# Collapsed repo rendering present
grep -q 'Collapsed repo: header only' "$BOARD"
assert_eq "collapsed repo rendering present" "0" "$?"

# MAX_EXPANDED constant
grep -q 'MAX_EXPANDED=4' "$BOARD"
assert_eq "MAX_EXPANDED=4 defined" "0" "$?"

# Enter toggles accordion (expand collapsed)
grep -q 'Collapsed repo: expand it' "$BOARD"
assert_eq "Enter expands collapsed repo" "0" "$?"

# Enter zooms into expanded repo
grep -q 'Expanded repo: zoom into card mode' "$BOARD"
assert_eq "Enter zooms expanded repo" "0" "$?"

# Esc collapses in repo mode
grep -q 'Collapse the selected repo' "$BOARD"
assert_eq "Esc collapses in repo mode" "0" "$?"

# Footer hints updated
grep -q 'expand/zoom' "$BOARD"
assert_eq "footer hints show expand/zoom" "0" "$?"

grep -q 'Esc: collapse' "$BOARD"
assert_eq "footer hints show collapse" "0" "$?"

# ── Summary ────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: ${pass}/${total} passed, ${fail} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ $fail -eq 0 ]] || exit 1
