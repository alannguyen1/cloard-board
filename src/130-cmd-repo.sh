# ── Repo commands ──────────────────────────────────────────────────────────────
cmd_repo() {
  local subcmd="${1:-}"
  shift 2>/dev/null || true
  case "$subcmd" in
    add)         cmd_repo_add "$@" ;;
    remove|rm)   cmd_repo_remove "$@" ;;
    list|ls)     cmd_repo_list "$@" ;;
    update-path) cmd_repo_update_path "$@" ;;
    archive)     cmd_repo_archive "$@" ;;
    unarchive)   cmd_repo_unarchive "$@" ;;
    *)           die "usage: cloard-board repo <add|remove|list|update-path|archive|unarchive>" ;;
  esac
}

# Internal: add a repo to state, returns the name used
_do_repo_add() {
  local rpath="$1"
  local rname="${2:-}"

  # Resolve canonical path
  rpath=$(cd "$rpath" && pwd -P)

  # Remove trailing slash
  rpath="${rpath%/}"

  # Derive name from basename if not provided
  [[ -n "$rname" ]] || rname=$(basename "$rpath")

  # Handle name collisions
  local original_name="$rname"
  local suffix=2
  while repo_exists "$rname"; do
    # Check if same path (already registered)
    local existing_path
    existing_path=$(repo_path "$rname")
    if [[ "$existing_path" == "$rpath" ]]; then
      die "repo '${rname}' is already registered at ${rpath}"
    fi
    rname="${original_name}-${suffix}"
    suffix=$((suffix + 1))
  done

  # Detect git or plain directory
  local rtype="dir"
  local base_branch=""
  if (cd "$rpath" && git rev-parse --show-toplevel &>/dev/null); then
    rtype="git"
    base_branch=$(cd "$rpath" && git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@' || echo "main")
  fi

  # Atomic write
  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.repos.XXXXXX")
  local now
  now=$(now_iso)
  jq --arg name "$rname" --arg path "$rpath" --arg type "$rtype" \
     --arg bb "$base_branch" --arg now "$now" \
    '.repos += [{
      name: $name,
      path: $path,
      type: $type,
      base_branch: (if $bb == "" then null else $bb end),
      archived: false,
      added_at: $now
    }]' "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state

  echo "$rname"
}

cmd_repo_add() {
  local rpath="${1:-$PWD}"

  # Normalize: remove trailing slash
  rpath="${rpath%/}"

  # Validate path exists
  [[ -d "$rpath" ]] || die "path does not exist: $rpath"

  local rname
  rname=$(_do_repo_add "$rpath")
  ok "registered '${rname}' (${rpath})"
}

cmd_repo_remove() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: cloard-board repo remove <name>"
  repo_exists "$name" || die "repo '${name}' not registered"

  # Warn about orphaned tasks
  local task_count
  task_count=$(jq -r --arg n "$name" '[.tasks[] | select(.repo == $n)] | length' "$GLOBAL_STATE")
  if [[ "$task_count" -gt 0 ]]; then
    warn "${task_count} task(s) will become orphaned"
  fi

  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.repos.XXXXXX")
  jq --arg n "$name" '.repos = [.repos[] | select(.name != $n)]' "$GLOBAL_STATE" > "$tmp" \
    && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state

  ok "removed repo '${name}'"
}

cmd_repo_list() {
  local show_all=false
  [[ "${1:-}" == "--all" ]] && show_all=true

  local count
  count=$(jq '.repos | length' "$GLOBAL_STATE")

  if [[ "$count" -eq 0 ]]; then
    info "no repos registered; run 'cloard-board repo add <path>' to register one"
    return 0
  fi

  printf "\n${C_BOLD}%-20s %-8s %-40s %-8s %-10s${C_RESET}\n" "NAME" "TYPE" "PATH" "TASKS" "STATUS"
  printf "%-20s %-8s %-40s %-8s %-10s\n" \
    "$(printf '%0.s─' {1..20})" "$(printf '%0.s─' {1..8})" \
    "$(printf '%0.s─' {1..40})" "$(printf '%0.s─' {1..8})" "$(printf '%0.s─' {1..10})"

  local repo_data task_count rstatus
  repo_data=$(jq -r '.repos[] | [.name, .type, .path, (if .archived == true then "true" else "false" end)] | join("\u001e")' "$GLOBAL_STATE")

  while IFS=$'\x1e' read -r rname rtype rpath rarchived; do
    [[ -n "$rname" ]] || continue
    if [[ "$show_all" != "true" && "$rarchived" == "true" ]]; then
      continue
    fi
    task_count=$(jq -r --arg n "$rname" '[.tasks[] | select(.repo == $n)] | length' "$GLOBAL_STATE")
    rstatus="active"
    [[ "$rarchived" == "true" ]] && rstatus="archived"
    [[ -d "$rpath" ]] || rstatus="stale"
    printf "%-20s %-8s %-40s %-8s %-10s\n" "$rname" "$rtype" "${rpath:0:40}" "$task_count" "$rstatus"
  done <<< "$repo_data"
  echo
}

cmd_repo_update_path() {
  local name="${1:-}" new_path="${2:-}"
  [[ -n "$name" ]] || die "usage: cloard-board repo update-path <name> <new-path>"
  [[ -n "$new_path" ]] || die "usage: cloard-board repo update-path <name> <new-path>"
  repo_exists "$name" || die "repo '${name}' not registered"
  [[ -d "$new_path" ]] || die "path does not exist: $new_path"

  new_path=$(cd "$new_path" && pwd -P)

  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.repos.XXXXXX")
  jq --arg n "$name" --arg p "$new_path" \
    '(.repos[] | select(.name == $n)).path = $p' "$GLOBAL_STATE" > "$tmp" \
    && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state

  ok "updated '${name}' path to ${new_path}"
}

cmd_repo_archive() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: cloard-board repo archive <name>"
  repo_exists "$name" || die "repo '${name}' not registered"

  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.repos.XXXXXX")
  jq --arg n "$name" '(.repos[] | select(.name == $n)).archived = true' "$GLOBAL_STATE" > "$tmp" \
    && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state

  ok "archived repo '${name}'"
}

cmd_repo_unarchive() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: cloard-board repo unarchive <name>"
  repo_exists "$name" || die "repo '${name}' not registered"

  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.repos.XXXXXX")
  jq --arg n "$name" '(.repos[] | select(.name == $n)).archived = false' "$GLOBAL_STATE" > "$tmp" \
    && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state

  ok "unarchived repo '${name}'"
}

