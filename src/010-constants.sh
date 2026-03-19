# ── Constants ──────────────────────────────────────────────────────────────────
readonly VERSION="0.3.0"
readonly TMUX_SOCKET="cloard-board"
readonly GLOBAL_DIR="$HOME/.cloard-board"
readonly GLOBAL_STATE="$GLOBAL_DIR/state.json"
readonly HOOKS_DIR="$GLOBAL_DIR/hooks"
readonly DASH_REFRESH="${CLOARD_REFRESH:-1}"  # seconds between dashboard refreshes
readonly HOOK_VERSION="4"
readonly MAX_SESSION_HISTORY=10
readonly TASK_REVIEW_IDLE_TIMEOUT_SECS=3600
readonly TASK_ACTIVE_IDLE_TIMEOUT_SECS=86400
readonly TASK_RUNTIME_GC_INTERVAL_SECS=60

# ── Colours (ANSI) ────────────────────────────────────────────────────────────
readonly C_RESET=$'\e[0m'
readonly C_BOLD=$'\e[1m'
readonly C_DIM=$'\e[2m'
readonly C_RED=$'\e[31m'
readonly C_GREEN=$'\e[32m'
readonly C_YELLOW=$'\e[33m'
readonly C_BLUE=$'\e[34m'
readonly C_MAGENTA=$'\e[35m'
readonly C_CYAN=$'\e[36m'
readonly C_WHITE=$'\e[37m'
readonly C_BG_BLUE=$'\e[44m'
readonly C_BG_DEFAULT=$'\e[49m'
