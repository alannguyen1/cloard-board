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

