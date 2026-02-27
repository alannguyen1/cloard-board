# New Task Creation Modal

## Overview

Replace the current sequential text prompts (dashboard `o` key) with a centered
overlay modal triggered by `c`. The modal displays all configurable fields at
once. Users navigate with Tab/Shift-Tab and submit with Enter.

The worktree toggle (previously removed from the dashboard flow) is restored
with a default of **No** (no worktree).

## Use Cases

### UC-1: Create a task while filtered to a repo

User is viewing a single repo's board and presses `c`. The modal opens with
the repo pre-filled and read-only. Focus starts on the Title field.

### UC-2: Create a task from the all-repos view

User is in the all-repos view and presses `c`. The modal opens with the Repo
field focused and set to `[select...]`. User opens the expandable dropdown,
picks a repo, then fills in the remaining fields.

### UC-3: Create a task with a worktree

User toggles the Worktree field to Yes (spacebar). The contextual hint updates
to "Isolated branch; merges back later". On creation, `cmd_start` uses
`claude --worktree`.

### UC-4: Create a task for a non-git repo

User selects a repo of type `dir`. The Worktree toggle locks to No and shows
"(not a git repo)". Tab skips the field.

### UC-5: No repos registered

User presses `c` with zero repos. The modal opens but shows a help message:
"No repos registered. Run: cloard-board repo add". Esc dismisses.

### UC-6: Cron job creation (context-aware)

User has the cron row selected and presses `c`. The existing cron creation flow
is triggered (same as current `o` behavior for cron row). No modal.

### UC-7: Single repo registered

Only one (non-archived) repo exists. Repo field auto-fills and becomes
read-only with "(only repo)" hint. Focus starts on Title.

## End-to-End Flows

### Flow A: Filtered Repo, Simple Task (most common)

```
Dashboard (filtered to "my-app")
  |
  | user presses 'c'
  v
Modal opens (dashboard frozen behind)
  Repo: my-app (read-only)
  Focus on Title field
  |
  | user types "fix auth bug", presses Tab
  v
Focus moves to Worktree
  Worktree: (No) selected, hint: "Works directly in the repo"
  |
  | user presses Tab (accepts default No)
  v
Focus moves to Prompt
  |
  | user types "fix the login token expiry issue"
  | text stays single-line (fits within field width)
  |
  | user presses Enter
  v
Modal shows: "Created t-005, Starting Claude..."
  |
  | ~1 second delay
  v
tmux switches to window "t-005" running Claude
Dashboard resumes refreshing when user returns (prefix-b)
```

### Flow B: All-Repos View, Repo Selection

```
Dashboard (all-repos view)
  |
  | user presses 'c'
  v
Modal opens
  Focus on Repo field: [select...]
  |
  | user presses Enter or Down on Repo field
  v
Expandable dropdown appears:
  +----------------+
  | > my-app       |
  |   api-server   |
  |   docs-site    |
  +----------------+
  |
  | user presses Down, then Enter on "api-server"
  v
Dropdown collapses. Repo shows "api-server"
Focus moves to Title
  |
  | (same flow as Flow A from here)
```

### Flow C: Worktree Enabled

```
Modal open, focus on Worktree field
  Worktree: (No)  (Yes)
  hint: "Works directly in the repo"
  |
  | user presses Space
  v
  Worktree: (No)  (*Yes*)
  hint: "Isolated branch; merges back later"
  |
  | user presses Tab, fills prompt, presses Enter
  v
Task created with worktree_mode="worktree"
cmd_start uses: claude --worktree t-005 --session-id <uuid> ...
```

### Flow D: Multi-line Prompt (auto-expand)

```
Focus on Prompt field (single line):
  Prompt: [fix the login token expiry issue that causes_]
  |
  | text exceeds field width, wraps to second line
  v
  Prompt: [fix the login token expiry issue that causes ]
          [users to be logged out after 5 minutes       ]
  |
  | continues typing, wraps to third line (max ~3-4 visible)
  v
  Prompt: [fix the login token expiry issue that causes ]
          [users to be logged out after 5 minutes. Also ]
          [check the refresh token endpoint_            ]
```

### Flow E: No Repos Registered

```
Dashboard (empty)
  |
  | user presses 'c'
  v
Modal opens with message:
  +------------------------------+
  |  No repos registered.        |
  |  Run: cloard-board repo add  |
  |                              |
  |  Esc: close                  |
  +------------------------------+
  |
  | user presses Esc
  v
Modal closes, dashboard resumes
```

## Modal Layout

### Standard (4 fields)

```
╔═══ New Task ══════════════════════════════════════╗
║                                                   ║
║  ▸ Repo:     my-project                           ║
║    Title:    [                                  ]  ║
║    Worktree: (•) No  ( ) Yes                       ║
║              └ Works directly in the repo          ║
║    Prompt:   [                                  ]  ║
║                                                   ║
║  Tab: next  Shift-Tab: prev  Enter: create        ║
║  Esc: cancel                                      ║
╚═══════════════════════════════════════════════════╝
```

### With Repo Dropdown Expanded

```
╔═══ New Task ══════════════════════════════════════╗
║                                                   ║
║  ▸ Repo:     [select...]                      ▼   ║
║              ┌───────────────────┐                 ║
║              │ ▸ my-project      │                 ║
║              │   api-server      │                 ║
║              │   docs-site       │                 ║
║              └───────────────────┘                 ║
║    Title:    [                                  ]  ║
║    Worktree: (•) No  ( ) Yes                       ║
║              └ Works directly in the repo          ║
║    Prompt:   [                                  ]  ║
║                                                   ║
║  ↑/↓: select  Enter: confirm  Esc: cancel         ║
╚═══════════════════════════════════════════════════╝
```

### Non-Git Repo Selected (Worktree Locked)

```
╔═══ New Task ══════════════════════════════════════╗
║                                                   ║
║    Repo:     scripts-dir                           ║
║  ▸ Title:    [organize utility scripts          ]  ║
║    Worktree: (•) No                (not a git repo)║
║    Prompt:   [                                  ]  ║
║                                                   ║
║  Tab: next  Shift-Tab: prev  Enter: create        ║
║  Esc: cancel                                      ║
╚═══════════════════════════════════════════════════╝
```

### Success State

```
╔═══ New Task ══════════════════════════════════════╗
║                                                   ║
║  ✓ Created t-005                                   ║
║    Starting Claude...                              ║
║                                                   ║
╚═══════════════════════════════════════════════════╝
```

### No Repos State

```
╔═══ New Task ══════════════════════════════════════╗
║                                                   ║
║  No repos registered.                              ║
║  Run: cloard-board repo add <path>                 ║
║                                                   ║
║  Esc: close                                        ║
╚═══════════════════════════════════════════════════╝
```

## Visual Design

- **Border**: Double-line Unicode box (`╔═╗║╚═╝`)
- **Focus indicator**: `▸` arrow before the active field label
- **Active text fields**: Show `[ ]` brackets with cursor
- **Inactive text fields**: Show `[ ]` brackets, dimmed
- **Toggle**: `(•) No  ( ) Yes` or `( ) No  (•) Yes`; spacebar toggles
- **Contextual hint**: Indented line below worktree toggle, changes with selection
- **Read-only fields**: No brackets, plain text, possibly dimmed
- **Footer**: Key hints at bottom of modal

## Sizing

- **Width**: Responsive. Min 40 columns, max 60 columns.
  Calculated as `min(60, max(40, terminal_cols - 10))`
- **Height**: Dynamic based on content (typically 10-14 lines)
- **Centering**: Horizontal and vertical center of terminal
- **Fallback**: If terminal is narrower than 40 columns, fall back to
  sequential text prompts (current behavior without modal)

## Keyboard Controls

| Key              | Context          | Action                              |
|------------------|------------------|-------------------------------------|
| `c`              | Dashboard        | Open modal (or cron create if cron row selected) |
| `Tab`            | Modal            | Move focus to next field            |
| `Shift-Tab`      | Modal            | Move focus to previous field        |
| `Enter`          | Repo (dropdown)  | Open/confirm dropdown selection     |
| `↑` / `↓`       | Repo dropdown    | Navigate dropdown options           |
| `Enter`          | Modal (any field)| Create task and auto-start          |
| `Esc`            | Modal            | Cancel and close modal              |
| `Esc`            | Repo dropdown    | Close dropdown without selecting    |
| `Space`          | Worktree toggle  | Toggle between Yes/No               |
| Typing           | Text fields      | Input characters                    |
| `Backspace`      | Text fields      | Delete last character               |
| `Ctrl-U`         | Text fields      | Clear entire field                  |
| `Ctrl-W`         | Text fields      | Delete last word                    |

## Field Definitions

### Repo (selector)

- **Pre-filled when**: Dashboard is filtered to a single repo, OR only one
  non-archived repo exists
- **Read-only when**: Pre-filled (Tab skips it)
- **Dropdown when**: Multiple repos available and not pre-filled
- **Read-only hint**: "(only repo)" when single repo

### Title (text input)

- **Default**: Empty (creates task with "(untitled)" if left blank)
- **Max display width**: Modal width minus label and padding

### Worktree (toggle)

- **Default**: No
- **Locked when**: Selected repo type is "dir" (not a git repo)
- **Locked hint**: "(not a git repo)"
- **Contextual hints**:
  - No: "Works directly in the repo"
  - Yes: "Isolated branch; merges back later"

### Prompt (text input)

- **Default**: Empty (starts Claude with no initial prompt)
- **Auto-expand**: Field grows to 2-3 visible lines when text wraps
  beyond the available width
- **Max visible lines**: 3-4 (scroll within if longer)

## State Changes

On successful creation:

1. `cmd_add` called with `--title`, `--repo`, and optionally `--no-worktree`
2. `cmd_start` called with task ID and optional prompt
3. Task status transitions: (new) -> pending -> active
4. Session UID generated and stored
5. tmux window created and switched to

## CLI Behavior (Unchanged)

The `cloard-board add` CLI command retains its current behavior:
- Worktree enabled by default for git repos
- `--no-worktree` flag to disable
- No modal; sequential prompts for missing fields

## Key Migration

- `o` key: Removed from dashboard (was: quick-create task)
- `c` key: New trigger for task creation modal
- `c` key in cron row: Triggers cron job creation (same as old `o` in cron row)

## Acceptance Testing Criteria

### AT-1: Modal opens on `c` key

- **Precondition**: Dashboard running with at least one repo
- **Steps**: Press `c`
- **Expected**: Centered double-line modal appears. Dashboard frozen behind it.
- **Success**: Modal visible, dashboard not refreshing, fields rendered

### AT-2: Tab navigation between fields

- **Precondition**: Modal open
- **Steps**: Press Tab repeatedly
- **Expected**: Focus arrow moves: Repo -> Title -> Worktree -> Prompt -> Repo
- **Success**: Arrow indicator moves correctly; Shift-Tab goes backward

### AT-3: Repo auto-fill when filtered

- **Precondition**: Dashboard filtered to "my-app"
- **Steps**: Press `c`
- **Expected**: Repo shows "my-app" (read-only), focus starts on Title
- **Success**: Repo field not editable, Tab skips it

### AT-4: Repo dropdown in all-repos view

- **Precondition**: Dashboard in all-repos view, 3+ repos
- **Steps**: Press `c`, Enter on Repo field
- **Expected**: Dropdown list appears with all non-archived repos
- **Steps**: Arrow down, Enter
- **Expected**: Repo selected, dropdown closes, focus moves to Title
- **Success**: Correct repo name displayed after selection

### AT-5: Worktree defaults to No

- **Precondition**: Modal open with git repo selected
- **Steps**: Observe Worktree field
- **Expected**: (•) No selected, hint: "Works directly in the repo"
- **Success**: Default is No, not Yes

### AT-6: Worktree toggle with Space

- **Precondition**: Modal open, focus on Worktree
- **Steps**: Press Space
- **Expected**: Toggles to Yes, hint changes to "Isolated branch; merges back later"
- **Steps**: Press Space again
- **Expected**: Toggles back to No
- **Success**: Toggle works, hint updates

### AT-7: Worktree locked for dir repos

- **Precondition**: Repo of type "dir" selected
- **Steps**: Tab to Worktree
- **Expected**: Shows "(•) No (not a git repo)", Tab skips it
- **Success**: Cannot toggle, field is read-only

### AT-8: Task creation with auto-start

- **Precondition**: Modal filled in (title, prompt)
- **Steps**: Press Enter
- **Expected**: Modal shows "Created t-NNN, Starting Claude...", then
  switches to Claude tmux window after ~1 second
- **Success**: Task in state.json with status "active", tmux window running

### AT-9: Prompt auto-expand

- **Precondition**: Modal open, focus on Prompt
- **Steps**: Type text longer than field width
- **Expected**: Field grows to 2 lines, then 3 as text continues wrapping
- **Success**: All typed text visible, modal height adjusts

### AT-10: Esc cancels at any point

- **Precondition**: Modal open, partially filled
- **Steps**: Press Esc
- **Expected**: Modal closes, no task created, dashboard resumes
- **Success**: No new task in state.json

### AT-11: No repos shows help

- **Precondition**: Zero non-archived repos
- **Steps**: Press `c`
- **Expected**: Modal with "No repos registered" message
- **Success**: Message displayed, Esc closes

### AT-12: Single repo auto-fill

- **Precondition**: Exactly one non-archived repo
- **Steps**: Press `c`
- **Expected**: Repo auto-filled with "(only repo)" hint, read-only
- **Success**: Focus starts on Title

### AT-13: Cron row context

- **Precondition**: Cron row selected
- **Steps**: Press `c`
- **Expected**: Cron job creation flow (not task modal)
- **Success**: Cron creation starts, no task modal

### AT-14: Small terminal fallback

- **Precondition**: Terminal width < 40 columns
- **Steps**: Press `c`
- **Expected**: Sequential text prompts (current behavior), no modal
- **Success**: Task creation still works without modal

### AT-15: Responsive modal width

- **Precondition**: Terminal width 80 columns
- **Steps**: Press `c`
- **Expected**: Modal width ~60 columns (min of 60, max of cols-10)
- **Precondition**: Terminal width 50 columns
- **Expected**: Modal width ~40 columns
- **Success**: Modal scales appropriately

### AT-16: Success flash before switch

- **Precondition**: Valid task created
- **Steps**: Press Enter to create
- **Expected**: "Created t-NNN" message visible for ~1 second
- **Success**: User can read the task ID before tmux switches

### AT-17: Empty title creates "(untitled)" task

- **Precondition**: Modal open
- **Steps**: Leave title empty, fill prompt, press Enter
- **Expected**: Task created with title "(untitled)"
- **Success**: state.json shows title "(untitled)"

### AT-18: Worktree mode stored correctly

- **Precondition**: Modal with worktree toggled to Yes
- **Steps**: Create task
- **Expected**: state.json has `worktree_mode: "worktree"` and
  `branch: "worktree-t-NNN"`
- **Success**: Correct fields in state

### AT-19: Old `o` key removed

- **Precondition**: Dashboard running
- **Steps**: Press `o`
- **Expected**: No action (key unbound or ignored)
- **Success**: No task creation triggered
