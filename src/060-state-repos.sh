# ── Repo helpers ──────────────────────────────────────────────────────────────
repo_exists() {
  local name="$1"
  [[ "$(jq -r --arg n "$name" '[.repos[] | select(.name == $n)] | length' "$GLOBAL_STATE")" -gt 0 ]]
}

repo_path() {
  local name="$1"
  jq -r --arg n "$name" '.repos[] | select(.name == $n) | .path' "$GLOBAL_STATE"
}

repo_type() {
  local name="$1"
  jq -r --arg n "$name" '.repos[] | select(.name == $n) | .type // "git"' "$GLOBAL_STATE"
}

repo_base_branch() {
  local name="$1"
  jq -r --arg n "$name" '.repos[] | select(.name == $n) | .base_branch // "main"' "$GLOBAL_STATE"
}

task_repo() {
  local id="$1"
  jq -r --arg id "$id" '.tasks[] | select(.id == $id) | .repo // ""' "$GLOBAL_STATE"
}

# Find which registered repo a Claude session belongs to by scanning ~/.claude/projects/
_find_session_repo() {
  local uid="$1"
  local session_file
  session_file=$(command find "$HOME/.claude/projects" -maxdepth 2 -name "${uid}.jsonl" -print -quit 2>/dev/null)
  [[ -n "$session_file" ]] || return 1

  local project_dir
  project_dir=$(basename "$(dirname "$session_file")")

  # For each registered repo, encode its path the way Claude does and compare
  local rname rpath
  while IFS=$'\x1e' read -r rname rpath; do
    [[ -n "$rname" ]] || continue
    local encoded="${rpath//\//-}"
    encoded="${encoded// /-}"
    if [[ "$project_dir" == "$encoded" ]]; then
      echo "$rname"
      return 0
    fi
  done < <(jq -r '.repos[] | select(.archived != true) | [.name, .path] | join("\u001e")' "$GLOBAL_STATE")

  return 1
}

_next_task_id() {
  _lock_state || return 1
  local num
  num=$(jq -r '.next_task_id' "$GLOBAL_STATE")
  local new_id
  new_id=$(printf "t-%03d" "$num")
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.tasks.XXXXXX")
  jq '.next_task_id += 1' "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
  echo "$new_id"
}

# Unlocked variant for migration (no concurrent access during first-time setup)
_next_task_id_unlocked() {
  local num
  num=$(jq -r '.next_task_id' "$GLOBAL_STATE")
  local new_id
  new_id=$(printf "t-%03d" "$num")
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.tasks.XXXXXX")
  jq '.next_task_id += 1' "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
  echo "$new_id"
}

