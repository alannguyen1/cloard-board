# ── Helpers ────────────────────────────────────────────────────────────────────
die()  { echo "${C_RED}error:${C_RESET} $*" >&2; exit 1; }
info() { echo "${C_CYAN}▸${C_RESET} $*"; }
ok()   { echo "${C_GREEN}✓${C_RESET} $*"; }
warn() { echo "${C_YELLOW}!${C_RESET} $*" >&2; }

require_cmd() {
  command -v "$1" &>/dev/null || die "'$1' is required but not found"
}

# Escape XML special characters for plist generation
_xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  echo "$s"
}

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

_iso_to_epoch() {
  [[ -n "${1:-}" ]] || return 1
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" "+%s" 2>/dev/null \
    || date -u -d "$1" "+%s" 2>/dev/null
}

# Compute a compact "time ago" string from an ISO timestamp.
# Sets _tago (avoids subshell). Empty string on invalid/missing input.
_time_ago() {
  [[ -z "${1:-}" ]] && { _tago=""; return; }
  local _ta_epoch
  TZ=UTC strftime -r -s _ta_epoch "%Y-%m-%dT%H:%M:%SZ" "$1" 2>/dev/null || { _tago=""; return; }
  local _ta_delta=$(( EPOCHSECONDS - _ta_epoch ))
  [[ $_ta_delta -lt 0 ]] && { _tago=""; return; }
  if   (( _ta_delta < 60 ));    then _tago="[<1m ago]"
  elif (( _ta_delta < 3600 ));  then _tago="[$((_ta_delta / 60))m ago]"
  elif (( _ta_delta < 86400 )); then _tago="[$((_ta_delta / 3600))h ago]"
  else                               _tago="[$((_ta_delta / 86400))d ago]"
  fi
}
