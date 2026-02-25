#!/usr/bin/env zsh
# cloard-board: multi-repo tmux kanban dashboard for Claude Code worktree sessions
# Usage: cloard-board <command> [args]
set -euo pipefail
setopt KSH_ARRAYS  # Use 0-based array indexing (C-style, consistent with loop conventions)
setopt TYPESET_SILENT  # Prevent typeset/local from printing values on re-declaration
# Capture stable script path at startup (realpath "$0" inside functions resolves incorrectly in zsh)
SCRIPT_PATH=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")

