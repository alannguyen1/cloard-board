#!/usr/bin/env zsh
setopt KSH_ARRAYS
setopt TYPESET_SILENT

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/cloard-board"
PASS=0 FAIL=0 CURRENT_GROUP=""

group() { CURRENT_GROUP="$1"; echo "\n${1}" }
assert() {
  local desc="$1" result="$2"
  if [[ "$result" == "0" ]]; then
    echo "  ✓ ${desc}"; PASS=$((PASS + 1))
  else
    echo "  ✗ ${desc}"; FAIL=$((FAIL + 1))
  fi
}
assert_match()  { echo "$3" | grep -qE "$2"; assert "$1" "$?" }
assert_no_match() { echo "$3" | grep -qE "$2"; assert "$1" "$(( $? == 0 ? 1 : 0 ))" }

# ── Token copy default ──────────────────────────────────────────────────────

group "Token copy default is opt-in (No)"

prompt_line=$(grep -n 'Copy environment from current shell' "$SCRIPT" | head -1)
assert_match "prompt shows [y/N]" '\[y/N\]' "$prompt_line"

logic_line=$(grep -A1 'Copy environment from current shell' "$SCRIPT" | tail -1)
# Should no longer match on nN (old default-yes logic)
assert_no_match "logic does not default to yes" '\!\s*"\$env_choice".*\^?\[nN\]' "$(grep -A3 'Copy environment from current shell' "$SCRIPT")"
assert_match "logic requires explicit yes" '\[yY\]' "$(grep -A3 'Copy environment from current shell' "$SCRIPT")"

# ── Env-var key validation ──────────────────────────────────────────────────

group "Env-var key validation"

# Check _generate_plist has validation
plist_section=$(sed -n '/_generate_plist()/,/^}/p' "$SCRIPT")
assert_match "plist generator validates env var names" 'A-Za-z_.*A-Za-z_0-9' "$plist_section"
assert_match "plist generator warns on invalid names" 'skipping invalid env var name' "$plist_section"

# Check cmd_cron_exec has validation
exec_section=$(sed -n '/cmd_cron_exec()/,/^}/p' "$SCRIPT")
assert_match "cron exec validates env var names" 'A-Za-z_.*A-Za-z_0-9' "$exec_section"
assert_match "cron exec warns on invalid names" 'skipping invalid env var name' "$exec_section"

# ── XML escaping ────────────────────────────────────────────────────────────

group "XML escape helper"

# Source just the helper function
eval "$(sed -n '/_xml_escape()/,/^}/p' "$SCRIPT")"

result=$(_xml_escape "hello & world")
assert_match "escapes ampersand" '&amp;' "$result"
assert_no_match "no raw ampersand" '& ' "$result"

result=$(_xml_escape "a < b > c")
assert_match "escapes less-than" '&lt;' "$result"
assert_match "escapes greater-than" '&gt;' "$result"

result=$(_xml_escape "no special chars")
[[ "$result" == "no special chars" ]]
assert "passes through clean strings" "$?"

result=$(_xml_escape "a&b<c>d")
[[ "$result" == "a&amp;b&lt;c&gt;d" ]]
assert "escapes all three in one string" "$?"

# ── XML escaping applied in plist ───────────────────────────────────────────

group "XML escaping applied in plist generation"

assert_match "plist label is escaped" 'esc_label' "$plist_section"
assert_match "plist script path is escaped" 'esc_script' "$plist_section"
assert_match "plist working dir is escaped" 'esc_working_dir' "$plist_section"
assert_match "plist log dir is escaped" 'esc_log_dir' "$plist_section"
assert_match "env var values use _xml_escape" '_xml_escape.*eval' "$plist_section"
assert_match "HOME default uses _xml_escape" '_xml_escape.*HOME' "$plist_section"

# ── .gitignore ──────────────────────────────────────────────────────────────

group ".gitignore entries"

gitignore=$(cat "$(dirname "$SCRIPT")/.gitignore")
assert_match "excludes .DS_Store" '\.DS_Store' "$gitignore"
assert_match "excludes .claude/" '\.claude/' "$gitignore"
assert_match "excludes reviews/" 'reviews/' "$gitignore"

# ── SECURITY.md ─────────────────────────────────────────────────────────────

group "SECURITY.md"

security_file="$(dirname "$SCRIPT")/SECURITY.md"
[[ -f "$security_file" ]]
assert "SECURITY.md exists" "$?"
assert_match "mentions vulnerability reporting" 'Reporting a Vulnerability' "$(cat "$security_file")"
assert_match "mentions threat model" 'threat model' "$(cat "$security_file")"

# ── Doc sanitization ────────────────────────────────────────────────────────

group "Doc path sanitization"

spec_file="$(dirname "$SCRIPT")/MULTI_REPO_SPEC.md"
spec_content=$(cat "$spec_file")
assert_no_match "no /Users/alan/ in spec" '/Users/alan/' "$spec_content"
assert_match "uses \$HOME/ in spec" '\$HOME/' "$spec_content"

# ── Results ─────────────────────────────────────────────────────────────────

echo "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: ${PASS}/$((PASS + FAIL)) passed, ${FAIL} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ $FAIL -eq 0 ]] || exit 1
