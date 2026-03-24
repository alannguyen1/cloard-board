# ── Dashboard TUI ──────────────────────────────────────────────────────────────

# Read a line from stdin; return 1 (cancelled) if user presses Esc.
# Uses raw mode throughout so Esc is detected at any position (not just first char).
# Manually echoes characters and handles backspace.
# Usage: _read_or_esc varname  -> sets varname, returns 0; or returns 1 on Esc/Ctrl-C.
_read_or_esc() {
  local _varname="$1"
  local _line=""
  stty -echo raw
  local _char=""
  while true; do
    read -rk1 _char 2>/dev/null || { stty echo -raw; eval "$_varname=''"; return 1; }
    case "$_char" in
      $'\e'|$'\x03')
        # Esc or Ctrl-C: drain buffered keys, cancel
        local _discard=""
        while read -rk1 -t 0.05 _discard 2>/dev/null; do :; done
        stty echo -raw
        echo ""
        eval "$_varname=''"
        return 1
        ;;
      $'\n'|$'\r')
        # Enter: submit
        stty echo -raw
        echo ""
        eval "$_varname=\${_line}"
        return 0
        ;;
      $'\x7f'|$'\b')
        # Backspace/Delete: remove last char
        if [[ -n "$_line" ]]; then
          _line="${_line%?}"
          printf '\b \b'
        fi
        ;;
      $'\x15')
        # Ctrl-U: kill entire line
        local _len=${#_line}
        while [[ $_len -gt 0 ]]; do
          printf '\b \b'
          _len=$((_len - 1))
        done
        _line=""
        ;;
      $'\x17')
        # Ctrl-W: kill last word (no EXTENDED_GLOB needed)
        local _old_len=${#_line}
        # Strip trailing spaces
        while [[ "$_line" == *' ' ]]; do
          _line="${_line% }"
        done
        # Strip the word (trailing non-spaces)
        while [[ -n "$_line" ]] && [[ "$_line" != *' ' ]]; do
          _line="${_line%?}"
        done
        local _erased=$((_old_len - ${#_line}))
        while [[ $_erased -gt 0 ]]; do
          printf '\b \b'
          _erased=$((_erased - 1))
        done
        ;;
      *)
        # Normal char: accumulate and echo
        _line="${_line}${_char}"
        printf '%s' "$_char"
        ;;
    esac
  done
}

# Column names and matching statuses
readonly -a COL_NAMES=("Pending" "Active" "Needs Review" "Done")
readonly -a CRON_COL_NAMES=("Scheduled" "Active" "Needs Review" "Done")
readonly -a COL_STATUSES=("pending" "active" "needs_review" "done")

# ASCII-safe glyph palette for the dashboard renderer. Ambiguous-width Unicode
# glyphs cause line wrapping drift in some tmux/terminal combinations.
readonly TUI_GLYPH_EXPANDED="v"
readonly TUI_GLYPH_COLLAPSED=">"
readonly TUI_GLYPH_ACTIVE="*"
readonly TUI_GLYPH_REVIEW="!"
readonly TUI_GLYPH_PENDING="o"
readonly TUI_GLYPH_PAUSED="="
readonly TUI_GLYPH_DONE="x"
readonly TUI_GLYPH_DISABLED="x"
readonly TUI_GLYPH_WORKING="*"
readonly TUI_GLYPH_WAITING="o"
readonly TUI_GLYPH_SCROLL_UP="^"
readonly TUI_GLYPH_SCROLL_DOWN="v"
readonly TUI_ELLIPSIS="..."

# Column colours
col_color() {
  case "$1" in
    0) echo "$C_DIM" ;;       # pending
    1) echo "$C_GREEN" ;;     # active
    2) echo "$C_YELLOW" ;;    # needs_review
    3) echo "$C_DIM" ;;       # done
  esac
}

# Truncate string to width
trunc() {
  local str="$1" max="$2"
  (( max > 0 )) || { echo ""; return; }

  if [[ ${#str} -le $max ]]; then
    echo "$str"
    return
  fi

  local ellipsis="${TUI_ELLIPSIS}"
  local ellipsis_len=${#ellipsis}
  if (( max <= ellipsis_len )); then
    echo "${str:0:$max}"
  else
    echo "${str:0:$((max - ellipsis_len))}${ellipsis}"
  fi
}

# Move cursor
move_to() { printf '\e[%d;%dH' "$1" "$2"; }

# Reset scroll region/origin mode so absolute cursor moves always target the
# full pane even if a previous app left constrained terminal state behind.
tui_reset_viewport() { printf '\e[r\e[?6l'; }

# Clear screen
cls() { printf '\e[2J\e[H'; }

# Hide/show cursor
cursor_hide() { printf '\e[?25l'; }
cursor_show() { printf '\e[?25h'; }
