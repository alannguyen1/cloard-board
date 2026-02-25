# ── Worktree helpers ───────────────────────────────────────────────────────────
find_worktree_path() {
  # Discover worktree path for a given branch/name from git worktree list
  # Optional second argument: repo directory to search in
  local id="$1"
  local repo_dir="${2:-}"
  local branch="worktree-${id}"
  if [[ -n "$repo_dir" ]]; then
    (cd "$repo_dir" && git worktree list --porcelain 2>/dev/null) | awk -v branch="refs/heads/$branch" '
      /^worktree / { path = substr($0, 10) }
      /^branch / { if ($2 == branch) print path }
    '
  else
    git worktree list --porcelain 2>/dev/null | awk -v branch="refs/heads/$branch" '
      /^worktree / { path = substr($0, 10) }
      /^branch / { if ($2 == branch) print path }
    '
  fi
}

