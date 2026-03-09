# ── Help ───────────────────────────────────────────────────────────────────────

cmd_help() {
  cat <<EOF
${C_BOLD}cloard-board${C_RESET} v${VERSION}
multi-repo tmux kanban dashboard for Claude Code worktree sessions

${C_BOLD}USAGE${C_RESET}
  cloard-board <command> [args]

${C_BOLD}REPO MANAGEMENT${C_RESET}
  repo add <path>              Register a directory (git or non-git)
  repo remove <name>           Unregister a repo
  repo list [--all]            List registered repos
  repo update-path <name> <p>  Update a repo's directory path
  repo archive <name>          Hide repo from dashboard
  repo unarchive <name>        Restore an archived repo

${C_BOLD}TASK COMMANDS${C_RESET}
  add [--title "..."] [--repo] Add a task (title optional, auto-ID)
                               Options: --no-worktree
  session <uid> [--repo] [--title]  Import a Claude session by UID
  title <id> <new-title>       Rename a task
  start <id> [prompt]          Start Claude in a worktree (status: active)
  pause <id>                   Pause a task (kill window, keep worktree)
  go <id>                      Switch to a task's tmux window
  resume <id>                  Reopen with claude --continue
  reopen <id> [prompt]         Reopen a done task (restarts session)
  advance <id>                 Move task to next status
  done <id>                    Clean up worktree and window (status: done)
  rm <id>                      Remove a task entirely
  list [--repo name]           Print all tasks as a table
  status <id>                  Show task and Claude status
  signal <id> <status>         Set Claude status (working|waiting|clear)

${C_BOLD}CRON JOBS${C_RESET}
  cron scan                    Discover Claude-invoking LaunchAgents
  cron add                     Create a new cron job (interactive)
  cron list                    List all cron jobs
  cron runs [job-id]           List active/unreviewed runs
  cron enable <id>             Enable and load a cron job
  cron disable <id>            Disable and unload a cron job
  cron remove <id>             Delete a cron job (with confirmation)
  cron review <run-id>         Mark a run as reviewed
  cron migrate                 Import existing Claude LaunchAgents

${C_BOLD}DASHBOARD${C_RESET}
  dash                         Open the interactive kanban dashboard
  attach                       Attach to the cloard-board tmux session
  doctor                       Check for orphaned worktrees/windows

${C_BOLD}SETUP${C_RESET}
  init                         Register current directory as a repo

${C_BOLD}OPTIONS${C_RESET}
  --help, -h                   Show this help
  --version, -v                Show version

${C_BOLD}EXAMPLES${C_RESET}
  cloard-board repo add ~/code/my-api
  cloard-board add --title "Fix auth bug" --repo my-api
  cloard-board cron scan
  cloard-board cron migrate
  cloard-board cron add
  cloard-board cron list
  cloard-board dash

${C_BOLD}DASHBOARD KEYS${C_RESET}
  All-repos view:
    j/k         Move between repo rows (cron row at bottom)
    h/l         Move between columns
    Enter       Zoom into repo (card-level nav)
    Esc         Zoom out to repo-level nav
    Tab         Next filter (All > Repo1 > Repo2 > ... > All)
    Shift-Tab   Previous filter

  Card-level / filtered view:
    j/k         Move between cards (overflows to next repo in all-repos view)
    h/l         Move between columns
    Enter       Open/start/attach to task
    o           Quick-create and start a Claude session
    S           Import an existing Claude session by UID
    t           Rename focused task
    p           Pause task
    r           Reopen done task (restart session)
    H           Browse session history for selected task
    x           Done/remove task
    </>         Move task left/right (change status)
    :/"         Reorder card up/down within column
    s           Show shell output
    d           Show git diff
    R           Register a new repo
    q           Quit (detach)

  Cron row:
    Enter       Col 0: show details / Col 1: attach / Col 2: resume session
    x           Col 0: toggle enable/disable / Col 2: mark reviewed
    o           Create new cron job
    D           Delete cron job (Col 0 only, with confirmation)

  View switching:
    v           Toggle between kanban and list view

  List view:
    j/k         Move cursor up/down through items
    Enter       Expand/collapse group, or open task (split mode)
    Tab         Jump to next group header
    Shift-Tab   Jump to previous group header
    </>         Cycle task status left/right
    H           Browse session history for selected task
    D           Toggle show/hide done tasks
    b           Toggle split view (sidebar + Claude session)
    l           Focus Claude pane (split mode)
    Ctrl-F      Toggle focus between sidebar and Claude pane
    F           Full-screen the Claude session (exits split)
    v           Switch back to kanban view
    ESC         Close split view or collapse current group
EOF
}

cmd_version() { echo "cloard-board v${VERSION}"; }

