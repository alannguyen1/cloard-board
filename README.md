# cloard-board

A tmux kanban dashboard for managing parallel [Claude Code](https://docs.anthropic.com/en/docs/claude-code) worktree sessions.

Run multiple Claude agents in isolated git worktrees, track their progress on an interactive terminal board, and advance tasks through a kanban workflow: pending, active, needs review, in PR, done.

## Install

**Option A: Clone and install**

```sh
git clone https://github.com/yourusername/cloard-board.git
cd cloard-board
./install.sh
```

**Option B: Manual**

```sh
curl -fsSL https://raw.githubusercontent.com/yourusername/cloard-board/main/cloard-board -o ~/.local/bin/cloard-board
chmod +x ~/.local/bin/cloard-board
```

Make sure `~/.local/bin` is in your `PATH`.

## Quick start

```sh
cd your-project        # any git repo
cloard-board init      # creates .cloard-board/ state directory
cloard-board add fix-auth --title "Fix authentication redirect loop"
cloard-board start fix-auth "Fix the auth redirect loop in middleware"
cloard-board dash      # open the interactive kanban dashboard
```

## Commands

| Command | Description |
|---|---|
| `init` | Initialise `.cloard-board/` in the current repo |
| `add <id> --title "..."` | Add a task (starts as pending). Use `--no-worktree` to skip branch isolation |
| `start <id> [prompt]` | Launch Claude in a new worktree; task becomes active |
| `pause <id>` | Pause a task: kill tmux window but keep worktree and branch |
| `go <id>` | Switch to a task's tmux window |
| `dash` | Open the interactive kanban dashboard |
| `attach` | Attach to the cloard-board tmux session |
| `review <id>` | Push branch, create a GitHub PR; task becomes "in review" |
| `done <id>` | Clean up worktree, branch, and tmux window; task is done |
| `resume <id>` | Reopen a task with `claude --continue` |
| `list` | Print all tasks as a table |
| `rm <id>` | Remove a task entirely (cleans up resources) |
| `advance <id>` | Move task to the next status in the pipeline |
| `doctor` | Check for orphaned worktrees or tmux windows |

## Dashboard keybindings

| Key | Action |
|---|---|
| `h` / `l` (or arrows) | Move between columns |
| `j` / `k` (or arrows) | Move between tasks in a column |
| `Enter` | Attach to the selected task's tmux window |
| `m` | Advance: move the selected task to the next status |
| `p` | Pause: kill the tmux window but keep the worktree (active/needs_review only) |
| `o` | Create a new task interactively |
| `x` | Mark task as done (or remove if already done) |
| `d` | Show git diff for the selected task's worktree |
| `r` | Resume: reopen task with `claude --continue` |
| `s` | Shell popup: view the task's terminal output |
| `q` | Quit (detach from tmux) |

## Task lifecycle

```
pending  -->  active  -->  needs_review  -->  review (PR)  -->  done
   add()      start()        advance()        review()        done()
                 \              |
                  <-- paused <--
                      pause()     resume()
```

Each `start` creates a git worktree and launches `claude --worktree <id>` in a dedicated tmux window. Multiple tasks run truly in parallel, each in their own isolated branch and directory.

### Pausing tasks

Use `pause` to temporarily free a tmux window without losing work. The worktree and branch remain intact. Resume later with `resume` or the `r` key in the dashboard. Paused tasks appear in the Pending column with cyan coloring.

### Worktree-free tasks

For quick fixes that don't need branch isolation, use `--no-worktree`:

```sh
cloard-board add fix-typo --title "Fix typo" --no-worktree
cloard-board start fix-typo "Fix the typo in README"
```

The dashboard also prompts "Use worktree? [Y/n]" when starting a task via the `m` key.

## Dependencies

- **zsh** (the script uses zsh-specific features)
- **tmux** (session and window management)
- **jq** (JSON state file manipulation)
- **git** (worktree management)
- **claude** ([Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code))
- **gh** (GitHub CLI, only needed for `review` command)

## How it works

cloard-board manages a JSON state file (`.cloard-board/tasks.json`) that tracks tasks, their statuses, branches, and PR URLs. It uses a dedicated tmux socket (`cloard-board`) to keep its session separate from your regular tmux sessions.

When you `start` a task, cloard-board:

1. Creates a new tmux window named after the task ID
2. Runs `claude --worktree <id>` inside that window, which creates an isolated git worktree
3. Updates the state file to mark the task as active

The `dash` command renders a 5-column kanban board in the terminal using ANSI escape codes and box-drawing characters, refreshing every second. Navigation uses vim-style keys.

## License

MIT
