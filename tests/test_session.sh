#!/usr/bin/env zsh
# Tests for session_uid auto-linking and dead window detection
setopt KSH_ARRAYS 2>/dev/null

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/cloard-board"
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)/src"
pass=0 fail=0
section() { echo ""; echo "$1"; }
assert() {
  local desc="$1" cond="$2"
  if eval "$cond"; then
    echo "  ✓ $desc"; pass=$((pass+1))
  else
    echo "  ✗ $desc"; fail=$((fail+1))
  fi
}

# ── Helper functions exist ─────────────────────────────────────────
section "Session helper functions"

assert "_tmux_claude_alive function exists" \
  'grep -q "_tmux_claude_alive()" "$SCRIPT"'

assert "_build_claude_resume_cmd function exists" \
  'grep -q "_build_claude_resume_cmd()" "$SCRIPT"'

assert "cmd__capture_session_uid function exists" \
  'grep -q "cmd__capture_session_uid()" "$SCRIPT"'

# ── Session ID generation in cmd_start ─────────────────────────────
section "Session ID in cmd_start"

assert "cmd_start generates session_uid via uuidgen" \
  'grep -A 5 "^cmd_start()" "$SCRIPT" | head -80 | grep -q "uuidgen" || grep -A 80 "^cmd_start()" "$SCRIPT" | grep -q "uuidgen"'

assert "--session-id flag used in cmd_start" \
  'sed -n "/^cmd_start/,/^cmd_/p" "$SCRIPT" | grep -q "\-\-session-id"'

assert "session_uid stored after window creation" \
  'sed -n "/^cmd_start/,/^cmd_/p" "$SCRIPT" | grep -q "update_task_field.*session_uid"'

# ── Resume uses --resume with session_uid ──────────────────────────
section "Resume uses --resume"

assert "_build_claude_resume_cmd uses --resume when session_uid set" \
  'sed -n "/_build_claude_resume_cmd/,/^}/p" "$SCRIPT" | grep -q "\-\-resume"'

assert "_build_claude_resume_cmd falls back to --continue" \
  'sed -n "/_build_claude_resume_cmd/,/^}/p" "$SCRIPT" | grep -q "\-\-continue"'

assert "cmd_resume uses _build_claude_resume_cmd" \
  'sed -n "/^cmd_resume/,/^cmd_/p" "$SCRIPT" | grep -q "_build_claude_resume_cmd"'

assert "cmd_reopen uses _build_claude_resume_cmd" \
  'sed -n "/^cmd_reopen/,/^cmd_/p" "$SCRIPT" | grep -q "_build_claude_resume_cmd"'

# ── Dead window detection ──────────────────────────────────────────
section "Dead window detection"

assert "_tmux_claude_alive checks pane_current_command" \
  'grep -A 8 "_tmux_claude_alive()" "$SCRIPT" | grep -q "pane_current_command"'

assert "cmd_resume kills dead windows" \
  'sed -n "/^cmd_resume/,/^cmd_/p" "$SCRIPT" | grep -q "_tmux_claude_alive"'

assert "dashboard paused handler kills dead windows" \
  'grep -B2 -A5 "paused)" "$SRC_DIR/180-cmd-dash.sh" | grep -q "_tmux_claude_alive"'

assert "dashboard active handler kills dead windows" \
  'grep -B2 -A5 "active|needs_review)" "$SRC_DIR/180-cmd-dash.sh" | grep -q "_tmux_claude_alive"'

# ── Fast dispatch for _capture-session-uid ─────────────────────────
section "Fast dispatch"

assert "_capture-session-uid in main dispatcher" \
  'grep -q "_capture-session-uid.*cmd__capture_session_uid" "$SCRIPT"'

assert "_capture-session-uid on fast path (before ensure_global_state)" \
  'sed -n "/# Fast paths/,/# Standard commands/p" "$SCRIPT" | grep -q "_capture-session-uid"'

# ── Hook includes session capture ──────────────────────────────────
section "Hook session capture"

assert "on-prompt hook calls _capture-session-uid" \
  'grep -q "_capture-session-uid" "$SRC_DIR/090-bootstrap.sh"'

# ── Dashboard pending handler generates session_uid ────────────────
section "Dashboard session tracking"

assert "dashboard pending generates session_uid" \
  'sed -n "/pending)/,/;;/p" "$SRC_DIR/180-cmd-dash.sh" | grep -q "uuidgen"'

assert "dashboard pending stores session_uid" \
  'sed -n "/pending)/,/;;/p" "$SRC_DIR/180-cmd-dash.sh" | grep -q "session_uid"'

assert "dashboard pending uses --session-id" \
  'sed -n "/pending)/,/;;/p" "$SRC_DIR/180-cmd-dash.sh" | grep -q "\-\-session-id"'

# ── cmd__capture_session_uid logic ─────────────────────────────────
section "Session capture logic"

assert "capture checks for existing session_uid" \
  'sed -n "/^cmd__capture_session_uid/,/^}/p" "$SCRIPT" | grep -q "already set"'

assert "capture scans .claude/projects for session files" \
  'sed -n "/^cmd__capture_session_uid/,/^}/p" "$SCRIPT" | grep -q "\.claude/projects"'

assert "capture extracts UUID from jsonl filename" \
  'sed -n "/^cmd__capture_session_uid/,/^}/p" "$SCRIPT" | grep -q "basename.*\.jsonl"'

# ── Summary ────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: $((pass+fail)) total, ${pass} passed, ${fail} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ $fail -eq 0 ]] && exit 0 || exit 1
