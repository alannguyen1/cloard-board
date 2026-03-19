# ── Main dispatcher ────────────────────────────────────────────────────────────
main() {
  require_cmd jq
  require_cmd tmux

  local cmd="${1:-help}"
  shift 2>/dev/null || true

  case "$cmd" in
    # Fast paths (no ensure_global_state)
    help|-h|--help)        cmd_help ;;
    version|-v|--version)  cmd_version ;;
    signal)                cmd_signal "$@" ;;
    _capture-session-uid)  cmd__capture_session_uid "$@" ;;
    cron-exec)
      ensure_global_state
      cmd_cron_exec "$@" ;;
    _cron_complete)
      ensure_global_state
      cmd__cron_complete "$@" ;;
    # Standard commands (ensure global state first)
    *)
      ensure_global_state
      check_and_migrate
      case "$cmd" in
        init)       cmd_init "$@" ;;
        repo)       cmd_repo "$@" ;;
        cron)       cmd_cron "$@" ;;
        add)        cmd_add "$@" ;;
        title)      cmd_title "$@" ;;
        session)    cmd_session "$@" ;;
        list|ls)    cmd_list "$@" ;;
        start)      cmd_start "$@" ;;
        go)         cmd_go "$@" ;;
        dash)       cmd_dash "$@" ;;
        attach)     cmd_attach "$@" ;;
        advance)    cmd_advance "$@" ;;
        done)       cmd_done "$@" ;;
        pause)      cmd_pause "$@" ;;
        resume)     cmd_resume "$@" ;;
        reopen)     cmd_reopen "$@" ;;
        rm|remove)  cmd_rm "$@" ;;
        status)     cmd_status "$@" ;;
        gc)         cmd_gc "$@" ;;
        doctor)     cmd_doctor "$@" ;;
        _dash_loop) cmd__dash_loop "$@" ;;
        _dash_switch) cmd__dash_switch "$@" ;;
        _split_session) cmd__split_session "$@" ;;
        *)          die "unknown command: ${cmd}; run 'cloard-board help'" ;;
      esac
      ;;
  esac
}

main "$@"
