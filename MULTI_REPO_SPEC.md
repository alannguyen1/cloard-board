# Multi-Repo Dashboard Spec

## Overview

Transform cloard-board from a single-repo tool into a centralized multi-repo orchestration dashboard. Users manage Claude Code sessions across multiple repositories from a single global dashboard, with tasks grouped by repo and the ability to filter views.

---

## Use Cases

### UC1: Register and manage repos
**Goal**: User registers repos they work on so the dashboard knows about them.
**Behavior**: `cloard-board repo add <path>` registers a directory (git or non-git). The repo appears in the dashboard. Users can list, remove, update paths, and archive repos.

### UC2: Create tasks for any registered repo
**Goal**: User creates a new task and assigns it to a specific repo.
**Behavior**: From the dashboard or CLI, user picks a repo then enters the task title. System auto-generates a unique ID. The task appears under that repo's row.

### UC3: Launch Claude Code sessions in different repos
**Goal**: User starts a Claude Code session that operates within the correct repo context.
**Behavior**: `cloard-board start <id>` looks up the task's associated repo, opens a tmux window, cd's to the repo (or worktree), and launches Claude with the right working directory.

### UC4: View all tasks grouped by repo
**Goal**: User sees a kanban dashboard with tasks organized by repo rows and status columns.
**Behavior**: Dashboard renders repo rows (one per registered repo with tasks), each containing the 5 status columns. Empty repos are collapsible.

### UC5: Filter dashboard by repo
**Goal**: User focuses on a single repo's tasks or views everything.
**Behavior**: Tab/Shift-Tab cycles through: All > Repo 1 > Repo 2 > ... > All. When filtered to a single repo, the layout collapses to the classic single-row kanban.

### UC6: Migrate from single-repo setup
**Goal**: Existing cloard-board users seamlessly transition to the global model.
**Behavior**: On first run, if a local `.cloard-board/tasks.json` exists but no global state, auto-migrate tasks and register the repo.

### UC7: Handle inaccessible repos
**Goal**: Dashboard gracefully handles repos whose paths no longer exist.
**Behavior**: Warning badge on the repo row. Tasks are visible but not actionable. User can update the path via `cloard-board repo update-path`.

---

## End-to-End Flows

### Flow 1: First-Time Global Setup

```
User runs: cloard-board dash (or any command)
    |
    v
Does ~/.cloard-board/ exist?
    |
    No ---> Create ~/.cloard-board/
    |       Create ~/.cloard-board/state.json (empty repos + tasks)
    |       Install global hooks in ~/.claude/settings.json
    |
    v
Does local .cloard-board/tasks.json exist in cwd?
    |
    Yes --> Prompt: "Migrate N tasks from <repo>? [Y/n]"
    |       If yes: import tasks, register repo, archive local state
    |
    v
Open dashboard
```

### Flow 2: Register a Repo

```
User runs: cloard-board repo add ~/code/my-api
    |
    v
Validate path exists
    |
    v
Detect: is it a git repo?
    |
    Yes --> Store: { path, name: "my-api", type: "git", base_branch: "main", archived: false }
    No  --> Store: { path, name: "my-api", type: "dir", archived: false }
    |
    v
Confirm: "Registered 'my-api' (~/code/my-api)"
```

### Flow 3: Create a Task (CLI)

```
User runs: cloard-board add --title "Fix auth bug" [--repo my-api]
    |
    v
Repo specified? ----No----> Is only 1 repo registered?
    |                            |
    Yes                     Yes: auto-select  |  No: prompt picker
    |                            |
    v                            v
Generate unique task ID (e.g., "t-007")
    |
    v
Add to state.json: { id, title, repo: "my-api", status: "pending", ... }
    |
    v
Confirm: "Created t-007 'Fix auth bug' in my-api"
```

### Flow 4: Create a Task (Dashboard, pressing 'o')

```
User presses 'o' in dashboard
    |
    v
Currently filtered to a specific repo?
    |
    Yes --> Skip picker, use that repo
    No  --> Show repo picker overlay (numbered list of repos)
            User selects repo
    |
    v
Prompt for task title (inline text input)
    |
    v
Generate unique ID, add to state, re-render dashboard
```

### Flow 5: Start a Task

```
User runs: cloard-board start <id> [prompt]
    (or presses Enter on a pending task in dashboard)
    |
    v
Look up task in state.json --> get repo path, repo type
    |
    v
Validate repo path exists (if not: error with suggestion to update-path)
    |
    v
Is repo type "git" AND worktree mode not "none"?
    |
    Yes --> Create worktree in repo dir: <repo>/worktree-<id>
    No  --> Use repo dir directly (--no-worktree)
    |
    v
Create tmux window (name: <id>)
Export: CLOARD_TASK_ID=<id>
        CLOARD_BOARD_DIR=~/.cloard-board
        CLOARD_REPO_PATH=<repo-path>
    |
    v
Launch: cd <working-dir> && claude [--worktree ...] [prompt]
    |
    v
Update state: status -> "active", started_at -> now
```

### Flow 6: Dashboard Rendering (Multi-Repo View)

```
+------------------------------------------------------------------+
| cloard-board -- All repos (12 tasks: 4 active, 2 review)        |
+------------------------------------------------------------------+
|                                                                  |
| [my-api] -------------------------------------------------------+
| Pending    | Active      | Needs Review | In PR    | Done        |
| +--------+ | +--------+  |              | +------+ |             |
| | t-007  | | | t-003  |  |              | |t-001 | |             |
| | Fix au | | | Add lo |  |              | |Setup | |             |
| | ○ wait | | | ● work |  |              | |      | |             |
| +--------+ | +--------+  |              | +------+ |             |
|            |              |              |          |             |
| [teacher-aide] ---------------------------------------------+    |
| Pending    | Active      | Needs Review | In PR    | Done        |
| +--------+ | +--------+  | +--------+   |          | +--------+  |
| | t-009  | | | t-005  |  | | t-004  |   |          | | t-002  |  |
| | New qu | | | Slide  |  | | Auth f |   |          | | Init p |  |
| |        | | | ● work |  | |        |   |          | |        |  |
| +--------+ | +--------+  | +--------+   |          | +--------+  |
|            |              |              |          |             |
| [scripts] (collapsed -- 0 tasks) ------  [click to expand]      |
|                                                                  |
+------------------------------------------------------------------+
| Tab: cycle repos | h/l: columns | j/k: repos | Enter: open      |
| o: new task | m: advance | p: pause | x: done | q: quit         |
+------------------------------------------------------------------+
```

### Flow 7: Dashboard Rendering (Filtered Single-Repo View)

```
+------------------------------------------------------------------+
| cloard-board -- my-api (5 tasks: 2 active, 1 review)            |
+------------------------------------------------------------------+
|                                                                  |
| Pending      | Active       | Needs Review | In PR    | Done     |
| +----------+ | +----------+ |              | +------+ | +------+ |
| | t-007    | | | t-003    | |              | |t-001 | | |t-006 | |
| | Fix auth | | | Add logs | |              | |Setup | | |Docs  | |
| | ○ wait   | | | ● work   | |              | |      | | |      | |
| +----------+ | +----------+ |              | +------+ | +------+ |
|              | +----------+ |              |          |           |
|              | | t-008    | |              |          |           |
|              | | Refactor | |              |          |           |
|              | | ● work   | |              |          |           |
|              | +----------+ |              |          |           |
|                                                                  |
+------------------------------------------------------------------+
| Tab: cycle repos | h/l: columns | j/k: cards | Enter: open      |
| o: new task | m: advance | p: pause | x: done | q: quit         |
+------------------------------------------------------------------+
```

### Flow 8: Navigation Model

**Multi-repo "All" view:**
```
j/k (up/down)  : Move between repo rows
h/l (left/right): Move between status columns
Enter           : "Zoom into" selected repo row (switches to card-level nav)
Esc             : "Zoom out" back to repo-level nav
```

**Inside a repo row (after Enter) or single-repo filtered view:**
```
j/k (up/down)  : Move between cards within the column
h/l (left/right): Move between status columns
Esc             : Back to repo-level nav (multi-repo view only)
```

**Filter cycling:**
```
Tab             : Next filter (All -> Repo 1 -> Repo 2 -> ... -> All)
Shift-Tab       : Previous filter
```

### Flow 9: Repo Path Update

```
User runs: cloard-board repo update-path my-api ~/new/location/my-api
    |
    v
Validate new path exists
    |
    v
Update repo entry in state.json
    |
    v
Check: any active worktrees at old path?
    |
    Yes --> Warn: "N active worktrees at old path. Tasks may need restarting."
    No  --> Confirm: "Updated 'my-api' path to ~/new/location/my-api"
```

---

## Data Model

### Global State: `~/.cloard-board/state.json`

```json
{
  "version": 2,
  "next_task_id": 8,
  "repos": [
    {
      "name": "my-api",
      "path": "$HOME/code/my-api",
      "type": "git",
      "base_branch": "main",
      "archived": false,
      "added_at": "2026-02-23T10:00:00Z"
    },
    {
      "name": "teacher-aide",
      "path": "$HOME/code/teacher-aide",
      "type": "git",
      "base_branch": "main",
      "archived": false,
      "added_at": "2026-02-23T10:05:00Z"
    },
    {
      "name": "scripts",
      "path": "$HOME/scripts",
      "type": "dir",
      "archived": false,
      "added_at": "2026-02-23T10:10:00Z"
    }
  ],
  "tasks": [
    {
      "id": "t-001",
      "title": "Fix authentication bug",
      "repo": "my-api",
      "status": "active",
      "worktree_mode": "worktree",
      "worktree": "$HOME/code/my-api/worktree-t-001",
      "branch": "worktree-t-001",
      "claude_status": "working",
      "pr_number": null,
      "pr_url": null,
      "created_at": "2026-02-23T10:15:00Z",
      "started_at": "2026-02-23T10:20:00Z",
      "completed_at": null
    }
  ]
}
```

### ID Generation

Auto-incrementing prefixed IDs: `t-001`, `t-002`, ..., `t-999`. The `next_task_id` counter in state.json tracks the next available number. IDs are zero-padded to 3 digits for consistent sorting.

---

## CLI Command Changes

### New Commands

| Command | Description |
|---|---|
| `cloard-board repo add <path>` | Register a directory as a repo |
| `cloard-board repo remove <name>` | Unregister a repo (tasks preserved in state, marked orphaned) |
| `cloard-board repo list` | List all registered repos with status |
| `cloard-board repo update-path <name> <new-path>` | Update a repo's directory path |
| `cloard-board repo archive <name>` | Hide repo from dashboard (tasks preserved) |
| `cloard-board repo unarchive <name>` | Restore an archived repo |

### Modified Commands

| Command | Change |
|---|---|
| `cloard-board init` | Repurposed: alias for `cloard-board repo add .` (register cwd) |
| `cloard-board add --title "..."` | Now requires `--repo <name>` (or auto-selects if 1 repo, or prompts) |
| `cloard-board start <id>` | Looks up repo from task, cd's to correct directory |
| `cloard-board review <id>` | Runs `gh pr create` from the task's repo directory |
| `cloard-board dash` | Renders multi-repo kanban with filtering |
| `cloard-board doctor` | Checks all registered repo paths and worktree health |

### Removed Commands

| Command | Reason |
|---|---|
| `cloard-board init` (old behavior) | Replaced by global setup + repo add |

---

## Hook Changes

### Global Hook Installation

Hooks are installed once in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.cloard-board/hooks/on-prompt.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.cloard-board/hooks/on-stop.sh"
          }
        ]
      }
    ]
  }
}
```

### Hook Environment Variables

When launching Claude, export:
- `CLOARD_TASK_ID`: the task's unique ID
- `CLOARD_BOARD_DIR`: always `~/.cloard-board`
- `CLOARD_REPO_PATH`: the repo's directory path

Hooks read `CLOARD_BOARD_DIR/state.json` and update the task matching `CLOARD_TASK_ID`.

### Hook Scripts Location

Hooks move from per-repo `.cloard-board/hooks/` to global `~/.cloard-board/hooks/`.

---

## Migration Flow

When any `cloard-board` command runs:

1. Check if `~/.cloard-board/state.json` exists
2. If not, create it with empty repos and tasks arrays
3. Check if cwd contains `.cloard-board/tasks.json` (old format)
4. If yes, prompt user: "Found local cloard-board state with N tasks. Migrate to global dashboard? [Y/n]"
5. If yes:
   - Register cwd as a repo
   - Import all tasks, assigning them to this repo
   - Generate new IDs (t-001, t-002, ...) for imported tasks
   - Rename local `.cloard-board/` to `.cloard-board.migrated/` (backup)
6. Install global hooks if not present

---

## Non-Git Directory Support

When a registered repo has `type: "dir"` (not a git repo):
- Tasks always use `worktree_mode: "none"`
- `start` launches Claude with `--no-worktree` flag, cd'd to the directory
- `review` command is disabled (no git, no PR)
- Dashboard cards show no branch indicator

---

## Stale Repo Handling

On each dashboard render cycle:
- Check if each visible repo's path exists (cheap `stat` call)
- If path missing: render repo row with warning indicator and "(path not found)" label
- Tasks in stale repos are visible but all action keybindings (start, resume, advance) are disabled
- User can fix via `cloard-board repo update-path <name> <new-path>`

---

## Acceptance Testing Criteria

### AT1: Global Setup

**Preconditions**: Fresh system with no `~/.cloard-board/` directory.

| Step | Action | Expected |
|---|---|---|
| 1 | Run `cloard-board dash` | Creates `~/.cloard-board/state.json` with version 2, empty repos and tasks |
| 2 | Check `~/.cloard-board/hooks/` | `on-prompt.sh` and `on-stop.sh` exist and are executable |
| 3 | Check `~/.claude/settings.json` | Contains UserPromptSubmit and Stop hooks pointing to global hooks |
| 4 | Dashboard opens | Shows empty state with helpful message ("No repos registered. Run cloard-board repo add <path>") |

**Edge cases**:
- `~/.claude/settings.json` already has other hooks: merge, don't overwrite
- `~/.cloard-board/` partially exists (e.g., directory but no state.json): recreate state.json

### AT2: Repo Registration

**Preconditions**: Global setup complete.

| Step | Action | Expected |
|---|---|---|
| 1 | `cloard-board repo add ~/code/my-api` (git repo) | Registered with type "git", base_branch auto-detected, name "my-api" |
| 2 | `cloard-board repo add ~/scripts` (non-git dir) | Registered with type "dir" |
| 3 | `cloard-board repo add ~/nonexistent` | Error: "Path does not exist" |
| 4 | `cloard-board repo add ~/code/my-api` (duplicate) | Error: "Repo 'my-api' is already registered" |
| 5 | `cloard-board repo list` | Shows both repos with paths, types, and task counts |
| 6 | `cloard-board repo remove my-api` | Repo removed from list; tasks marked as orphaned |
| 7 | `cloard-board repo archive scripts` | Repo hidden from dashboard but in `repo list --all` |
| 8 | `cloard-board repo unarchive scripts` | Repo visible again |

**Edge cases**:
- Two directories with the same basename (e.g., `~/work/api` and `~/personal/api`): second one gets suffix, e.g., "api-2"
- Path with trailing slash: normalize to no trailing slash
- Symlinked paths: resolve to canonical path

### AT3: Task Creation

**Preconditions**: Two repos registered: "my-api" (git) and "scripts" (dir).

| Step | Action | Expected |
|---|---|---|
| 1 | `cloard-board add --title "Fix bug" --repo my-api` | Task created with auto-ID (e.g., t-001), repo set to "my-api" |
| 2 | `cloard-board add --title "Cleanup"` (1 repo would auto-select, but 2 exist) | Prompts for repo selection |
| 3 | `cloard-board add --title "Quick fix" --repo nonexistent` | Error: "Repo 'nonexistent' not registered" |
| 4 | Press 'o' in dashboard filtered to "my-api" | Skips repo picker, prompts for title only |
| 5 | Press 'o' in dashboard on "All repos" view | Shows repo picker, then title prompt |

**Edge cases**:
- Creating task in archived repo: error
- Creating task in stale-path repo: error with suggestion to update path

### AT4: Task Lifecycle (Start, Pause, Resume, Review, Done)

**Preconditions**: Task t-001 exists in "my-api" (git repo), status pending.

| Step | Action | Expected |
|---|---|---|
| 1 | `cloard-board start t-001` | Creates worktree in my-api dir, opens tmux window, launches Claude, status -> active |
| 2 | Verify tmux window | Window named "t-001", cwd is the worktree path inside my-api |
| 3 | Verify env vars in tmux | CLOARD_TASK_ID=t-001, CLOARD_BOARD_DIR=~/.cloard-board, CLOARD_REPO_PATH=~/code/my-api |
| 4 | `cloard-board pause t-001` | Kills tmux window, status -> paused, worktree preserved |
| 5 | `cloard-board resume t-001` | Reopens tmux window, launches Claude with --continue, status -> active |
| 6 | `cloard-board review t-001` | Runs `gh pr create` from my-api dir, stores PR URL, status -> review |
| 7 | `cloard-board done t-001` | Cleans up worktree, status -> done |

**Non-git repo variant (task t-002 in "scripts"):**

| Step | Action | Expected |
|---|---|---|
| 1 | `cloard-board start t-002` | No worktree created, tmux window cwd is ~/scripts, Claude launched with --no-worktree |
| 2 | `cloard-board review t-002` | Error: "Review not available for non-git repos" |

### AT5: Dashboard Multi-Repo View

**Preconditions**: 3 repos registered with varying task counts.

| Step | Action | Expected |
|---|---|---|
| 1 | `cloard-board dash` | Dashboard shows repo rows sorted by registration order |
| 2 | Repo with 0 tasks | Shown as collapsed single line: "[scripts] (0 tasks)" |
| 3 | Press j/k | Cursor moves between repo rows; selected row highlighted |
| 4 | Press h/l | Cursor moves between status columns within selected repo |
| 5 | Press Enter on a repo row | Zooms in: j/k now navigates cards within that repo |
| 6 | Press Esc (zoomed in) | Zooms out: back to repo-level navigation |
| 7 | Press Enter on a specific card (zoomed in) | Opens/starts/attaches to that task |
| 8 | Title bar | Shows "cloard-board -- All repos (12 tasks: 4 active, 2 review)" |

### AT6: Dashboard Filtering

**Preconditions**: Multiple repos with tasks.

| Step | Action | Expected |
|---|---|---|
| 1 | Press Tab | Filter changes: All -> my-api. Title bar updates. Only my-api tasks shown (single-row layout) |
| 2 | Press Tab again | Filter changes: my-api -> teacher-aide |
| 3 | Press Shift-Tab | Filter changes back: teacher-aide -> my-api |
| 4 | Press Tab until cycling back to All | Returns to multi-repo row layout |
| 5 | Create task while filtered | Task auto-assigned to filtered repo |

### AT7: Migration from Single-Repo

**Preconditions**: Existing `.cloard-board/tasks.json` in a repo with 3 tasks.

| Step | Action | Expected |
|---|---|---|
| 1 | Run `cloard-board dash` from repo with local state | Prompt: "Found local state with 3 tasks. Migrate? [Y/n]" |
| 2 | Accept migration | Repo registered, tasks imported with new IDs (t-001, t-002, t-003) |
| 3 | Check old state | `.cloard-board/` renamed to `.cloard-board.migrated/` |
| 4 | Run `cloard-board dash` again | No migration prompt; dashboard shows imported tasks |
| 5 | Decline migration | Local state untouched, global state empty, dashboard opens normally |

### AT8: Stale Repo Handling

**Preconditions**: Repo "my-api" registered with path that no longer exists.

| Step | Action | Expected |
|---|---|---|
| 1 | Open dashboard | "my-api" row shows warning indicator and "(path not found)" |
| 2 | Try to start a task in stale repo | Error message: "Repo path not found. Run: cloard-board repo update-path my-api <new-path>" |
| 3 | `cloard-board repo update-path my-api ~/new/my-api` | Path updated, warning clears on next render |
| 4 | `cloard-board repo update-path my-api ~/nonexistent` | Error: "Path does not exist" |

### AT9: Hook Integration

**Preconditions**: Task t-001 active, Claude session running.

| Step | Action | Expected |
|---|---|---|
| 1 | User submits prompt in Claude session | on-prompt.sh fires, claude_status -> "working" in state.json |
| 2 | Claude stops (completes response) | on-stop.sh fires, claude_status -> "waiting" |
| 3 | Dashboard updates on next render cycle | Card shows green dot (working) or yellow dot (waiting) |
| 4 | Hook fires for a task that's been marked "done" | Hook is a no-op (doesn't update done tasks) |

### AT10: Concurrent Operations

| Step | Action | Expected |
|---|---|---|
| 1 | Two hooks fire simultaneously for different tasks | Both state updates succeed (no data loss) |
| 2 | User pauses a task while hook is updating it | Final state is consistent (pause wins) |
| 3 | Dashboard renders while state is being written | Dashboard reads a consistent snapshot (no partial JSON) |

---

## Out of Scope (for initial implementation)

- Multi-repo PRs (tasks spanning changes in multiple repos)
- Per-repo hook customization (global hooks only)
- Remote repo support (all repos must be local paths)
- Task dependencies or ordering within a repo
- Collaborative/multi-user dashboard

---

## Cron Jobs (v0.3.0)

### Overview

Automated Claude Code sessions run via macOS launchd are surfaced on the dashboard with full lifecycle management: discovery, execution, review, and session resumption.

### Use Cases

#### UC8: Discover existing Claude cron jobs
**Goal**: User finds which LaunchAgents invoke Claude Code.
**Behavior**: `cloard-board cron scan` scans `~/Library/LaunchAgents/*.plist`, checking both direct ProgramArguments and referenced shell scripts for "claude". Displays label, plist path, working directory, and schedule.

#### UC9: Migrate existing cron jobs
**Goal**: User imports existing Claude LaunchAgents into cloard-board management.
**Behavior**: `cloard-board cron migrate` scans for Claude plists, extracts schedule/env/command, creates managed cron jobs, generates new plists that call `cloard-board cron-exec`, and archives old plists.

#### UC10: Create a new cron job
**Goal**: User sets up a new scheduled Claude session from the CLI or dashboard.
**Behavior**: `cloard-board cron add` (or `o` on the cron row) prompts for working dir, name, schedule (daily/hourly/interval presets), Claude command, and env vars. Generates a launchd plist and loads it.

#### UC11: View cron jobs on the dashboard
**Goal**: User sees scheduled, running, and completed cron runs alongside their task board.
**Behavior**: Dashboard shows a "cron jobs" row at the bottom with 3 columns: Scheduled (enabled jobs), Active (running sessions), Needs Review (completed, unreviewed).

#### UC12: Resume a completed cron session
**Goal**: User interactively continues a headless cron session.
**Behavior**: Press Enter on a Needs Review card to open a new tmux window running `claude --resume <session-id>`.

#### UC13: Review and dismiss completed runs
**Goal**: User acknowledges a completed cron run.
**Behavior**: Press `x` on a Needs Review card to mark it reviewed (it disappears). Unreviewed runs auto-archive after 24 hours.

### State Schema (v3)

Added fields to `~/.cloard-board/state.json`:

```json
{
  "version": 3,
  "next_cron_id": 1,
  "next_run_id": 1,
  "cron_jobs": [{
    "id": "cj-001",
    "label": "com.cloard-board.morning-routine",
    "name": "morning-routine",
    "plist_path": "/path/to/plist",
    "working_dir": "/path/to/dir",
    "claude_command": "claude -p \"...\" --model ...",
    "schedule_type": "daily|hourly|interval",
    "schedule_desc": "Daily at 08:30",
    "schedule_raw": {"Hour": 8, "Minute": 30},
    "enabled": true,
    "created_at": "...",
    "env_vars": {"CLAUDE_CODE_OAUTH_TOKEN": "...", "PATH": "..."}
  }],
  "cron_runs": [{
    "run_id": "cr-001",
    "cron_job_id": "cj-001",
    "session_id": "uuid",
    "tmux_window": "cron-cj-001-1708776600",
    "started_at": "...",
    "completed_at": "...",
    "exit_code": 0,
    "status": "active|needs_review|reviewed|archived"
  }]
}
```

### Dashboard Layout

```
+------------------------------------------------------------------+
| cloard-board -- All repos (N tasks: M active, P review)          |
| [repo-a] (3 tasks)                                               |
|   Pending    Active    Needs Review    In PR    Done              |
|   ...cards...                                                     |
| [repo-b] (2 tasks)                                               |
|   ...cards...                                                     |
| [cron jobs] (N items)                                            |
|   Scheduled    Active    Needs Review                            |
|   cj-001       cr-003    cr-002                                  |
|   morning...   running   exit 0                                  |
+------------------------------------------------------------------+
```

### Acceptance Criteria

| # | Scenario | Expected |
|---|----------|----------|
| 1 | `cron scan` with Claude-invoking plists | Detects both direct and script-indirect invocations |
| 2 | `cron migrate` on existing LaunchAgent | Creates managed job, generates new plist, archives old |
| 3 | `cron add` with daily schedule | Creates plist with StartCalendarInterval, loads it |
| 4 | `cron-exec` while another run is active | Skips execution, logs skip message |
| 5 | Cron run completes | Status changes to needs_review, exit code recorded |
| 6 | `cron review <run-id>` | Status changes to reviewed, card disappears from dashboard |
| 7 | Unreviewed run older than 24h | Auto-archived during cleanup |
| 8 | Dashboard cron row renders | 3 columns: Scheduled, Active, Needs Review |
| 9 | Enter on Needs Review cron card | Opens tmux window with `claude --resume <session-id>` |
| 10 | `x` on Scheduled card | Toggles enable/disable with confirmation |
| 11 | `D` on Scheduled card | Deletes job with DELETE confirmation |
| 12 | Schema migration v2 to v3 | Adds cron fields without losing existing data |
| 13 | `doctor` with missing plist | Reports missing plist as issue |
| 14 | `doctor` prunes old runs | Removes archived/reviewed runs older than 7 days |
