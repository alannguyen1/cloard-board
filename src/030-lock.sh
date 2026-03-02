# ── Lock helpers (mkdir-based, portable to macOS) ─────────────────────────────
_lock_state() {
  local lockdir="${GLOBAL_DIR}/.lock"
  local pidfile="${lockdir}/pid"
  local retries=100
  while ! mkdir "$lockdir" 2>/dev/null; do
    # Stale lock detection: if the holding process is dead, reclaim the lock
    if [[ -f "$pidfile" ]]; then
      local holder_pid
      holder_pid=$(<"$pidfile")
      if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
        rmdir "$lockdir" 2>/dev/null || rm -rf "$lockdir" 2>/dev/null || true
        continue
      fi
    else
      # Lock dir exists but no PID file; treat as stale after brief wait
      if [[ $retries -le 90 ]]; then
        rmdir "$lockdir" 2>/dev/null || rm -rf "$lockdir" 2>/dev/null || true
        continue
      fi
    fi
    retries=$((retries - 1))
    if [[ $retries -le 0 ]]; then
      warn "could not acquire state lock"
      return 1
    fi
    sleep 0.02
  done
  echo $$ > "$pidfile" 2>/dev/null || true
}

_unlock_state() {
  rm -f "${GLOBAL_DIR}/.lock/pid" 2>/dev/null || true
  rmdir "${GLOBAL_DIR}/.lock" 2>/dev/null || true
}

