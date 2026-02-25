# ── Lock helpers (mkdir-based, portable to macOS) ─────────────────────────────
_lock_state() {
  local lockdir="${GLOBAL_DIR}/.lock"
  local retries=100
  while ! mkdir "$lockdir" 2>/dev/null; do
    retries=$((retries - 1))
    if [[ $retries -le 0 ]]; then
      warn "could not acquire state lock"
      return 1
    fi
    sleep 0.02
  done
}

_unlock_state() {
  rmdir "${GLOBAL_DIR}/.lock" 2>/dev/null || true
}

