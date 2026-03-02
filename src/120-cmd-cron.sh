# ── Cron commands ─────────────────────────────────────────────────────────────

cmd_cron() {
  local subcmd="${1:-}"
  shift 2>/dev/null || true
  case "$subcmd" in
    scan)      cmd_cron_scan "$@" ;;
    add)       cmd_cron_add "$@" ;;
    list|ls)   cmd_cron_list "$@" ;;
    runs)      cmd_cron_runs "$@" ;;
    enable)    cmd_cron_enable "$@" ;;
    disable)   cmd_cron_disable "$@" ;;
    remove|rm) cmd_cron_remove "$@" ;;
    review)    cmd_cron_review "$@" ;;
    migrate)   cmd_cron_migrate "$@" ;;
    *)         die "usage: cloard-board cron <scan|add|list|runs|enable|disable|remove|review|migrate>" ;;
  esac
}

cmd_cron_scan() {
  info "scanning ~/Library/LaunchAgents for Claude-invoking jobs..."
  local found=0
  while IFS=$'\x1e' read -r label ppath wdir sdesc sjson; do
    [[ -n "$label" ]] || continue
    found=$((found + 1))
    echo ""
    echo "  ${C_BOLD}${label}${C_RESET}"
    echo "  plist: ${ppath}"
    echo "  working dir: ${wdir}"
    echo "  schedule: ${sdesc}"
  done < <(_scan_launch_agents)

  if [[ $found -eq 0 ]]; then
    echo "  ${C_DIM}no Claude-invoking LaunchAgents found${C_RESET}"
  else
    echo ""
    info "found ${found} job(s). Run 'cloard-board cron migrate' to import them."
  fi
}

cmd_cron_add() {
  # Interactive: working dir, schedule, Claude command, job name
  local name="" working_dir="" claude_cmd="" schedule_type="" schedule_desc="" schedule_raw=""

  # Working directory
  printf "${C_CYAN}Working directory: ${C_RESET}"
  read -r working_dir
  working_dir="${working_dir%$'\r'}"
  working_dir="${working_dir## }"
  working_dir="${working_dir%% }"
  working_dir="${(Q)working_dir}"
  [[ -d "$working_dir" ]] || die "directory not found: ${working_dir}"

  # Job name
  printf "${C_CYAN}Job name (e.g. morning-routine): ${C_RESET}"
  read -r name
  name="${name%$'\r'}"
  name="${name## }"
  name="${name%% }"
  [[ -n "$name" ]] || die "name is required"
  # Sanitize: lowercase, hyphens only
  name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | tr -cd 'a-z0-9-')

  # Schedule
  echo "${C_CYAN}Schedule:${C_RESET}"
  echo "  1) Daily at HH:MM"
  echo "  2) Hourly (within a time range)"
  echo "  3) Every N minutes (within a time range)"
  printf "${C_CYAN}Choice [1-3]: ${C_RESET}"
  local stype_choice=""
  read -r stype_choice
  case "$stype_choice" in
    1)
      schedule_type="daily"
      printf "${C_CYAN}Time (HH:MM, 24h): ${C_RESET}"
      local time_str=""
      read -r time_str
      local hour minute
      hour=$(echo "$time_str" | cut -d: -f1 | sed 's/^0//')
      minute=$(echo "$time_str" | cut -d: -f2 | sed 's/^0//')
      schedule_desc="Daily at ${time_str}"
      schedule_raw=$(jq -n --argjson h "$hour" --argjson m "$minute" '{Hour: $h, Minute: $m}')
      ;;
    2)
      schedule_type="hourly"
      printf "${C_CYAN}Start hour (0-23): ${C_RESET}"
      local start_h="" end_h="" at_min=""
      read -r start_h
      printf "${C_CYAN}End hour (0-23): ${C_RESET}"
      read -r end_h
      printf "${C_CYAN}At minute (0-59) [0]: ${C_RESET}"
      read -r at_min
      [[ -n "$at_min" ]] || at_min=0
      schedule_desc="Hourly ${start_h}:$(printf '%02d' "$at_min")-${end_h}:$(printf '%02d' "$at_min")"
      schedule_raw="["
      local h_sep=""
      for (( h=start_h; h<=end_h; h++ )); do
        schedule_raw="${schedule_raw}${h_sep}{\"Hour\":${h},\"Minute\":${at_min}}"
        h_sep=","
      done
      schedule_raw="${schedule_raw}]"
      ;;
    3)
      schedule_type="interval"
      printf "${C_CYAN}Interval in minutes (1-59, e.g. 30): ${C_RESET}"
      local interval="" start_h="" end_h=""
      read -r interval
      if [[ ! "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -lt 1 || "$interval" -gt 59 ]]; then
        die "interval must be a number between 1 and 59"
      fi
      printf "${C_CYAN}Start hour (0-23): ${C_RESET}"
      read -r start_h
      printf "${C_CYAN}End hour (0-23): ${C_RESET}"
      read -r end_h
      schedule_desc="Every ${interval}m ${start_h}:00-${end_h}:00"
      schedule_raw="["
      local h_sep=""
      for (( h=start_h; h<=end_h; h++ )); do
        for (( m=0; m<60; m+=interval )); do
          schedule_raw="${schedule_raw}${h_sep}{\"Hour\":${h},\"Minute\":${m}}"
          h_sep=","
        done
      done
      schedule_raw="${schedule_raw}]"
      ;;
    *)
      die "invalid schedule choice"
      ;;
  esac

  # Claude command
  echo "${C_CYAN}Claude command (the full 'claude -p \"...\" --model ... --allowedTools ...' line):${C_RESET}"
  printf "${C_CYAN}> ${C_RESET}"
  read -r claude_cmd
  [[ -n "$claude_cmd" ]] || die "claude command is required"

  # Environment variables
  local env_vars="{}"
  printf "${C_CYAN}Copy environment from current shell? (CLAUDE_CODE_OAUTH_TOKEN, PATH) [y/N]: ${C_RESET}"
  local env_choice=""
  read -r env_choice
  if [[ "$env_choice" =~ ^[yY]$ ]]; then
    env_vars=$(jq -n \
      --arg token "${CLAUDE_CODE_OAUTH_TOKEN:-}" \
      --arg home "$HOME" \
      --arg path "$PATH" \
      '{CLAUDE_CODE_OAUTH_TOKEN: $token, HOME: $home, PATH: $path} | with_entries(select(.value != ""))')
  fi

  # Create cron job in state
  local cron_id
  cron_id=$(_next_cron_id)

  _lock_state || die "could not acquire lock"
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.cron.XXXXXX")
  jq --arg id "$cron_id" --arg name "$name" --arg wdir "$working_dir" \
    --arg cmd "$claude_cmd" --arg stype "$schedule_type" --arg sdesc "$schedule_desc" \
    --argjson sraw "$schedule_raw" --argjson env "$env_vars" --arg now "$(now_iso)" '
    .cron_jobs += [{
      id: $id, label: "", name: $name, plist_path: "",
      working_dir: $wdir, claude_command: $cmd,
      schedule_type: $stype, schedule_desc: $sdesc, schedule_raw: $sraw,
      enabled: true, created_at: $now, env_vars: $env
    }]
  ' "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state

  # Generate and load plist
  local plist_path
  plist_path=$(_generate_plist "$cron_id")
  launchctl load "$plist_path" 2>/dev/null || warn "failed to load plist (may need manual load)"
  ok "created cron job ${cron_id} '${name}' (${schedule_desc})"
  info "plist: ${plist_path}"
}

cmd_cron_list() {
  local jobs
  jobs=$(jq -r '.cron_jobs[] | [.id, .name, .schedule_desc, (if .enabled then "enabled" else "disabled" end)] | join("\u001e")' "$GLOBAL_STATE" 2>/dev/null) || true

  if [[ -z "$jobs" ]]; then
    echo "  ${C_DIM}no cron jobs configured${C_RESET}"
    return
  fi

  printf "${C_BOLD}%-10s %-25s %-35s %s${C_RESET}\n" "ID" "Name" "Schedule" "Status"
  while IFS=$'\x1e' read -r cid cname cschedule cstatus; do
    [[ -n "$cid" ]] || continue
    local sc=""
    [[ "$cstatus" == "enabled" ]] && sc="${C_GREEN}" || sc="${C_RED}"
    printf "%-10s %-25s %-35s ${sc}%s${C_RESET}\n" "$cid" "$cname" "$cschedule" "$cstatus"
  done <<< "$jobs"
}

cmd_cron_runs() {
  local filter_id="${1:-}"
  local runs
  if [[ -n "$filter_id" ]]; then
    runs=$(jq -r --arg id "$filter_id" '
      .cron_runs[] | select(.cron_job_id == $id and (.status == "active" or .status == "needs_review")) |
      [.run_id, .cron_job_id, .status, .started_at, (.exit_code | tostring)] | join("\u001e")
    ' "$GLOBAL_STATE" 2>/dev/null) || true
  else
    runs=$(jq -r '
      .cron_runs[] | select(.status == "active" or .status == "needs_review") |
      [.run_id, .cron_job_id, .status, .started_at, (.exit_code | tostring)] | join("\u001e")
    ' "$GLOBAL_STATE" 2>/dev/null) || true
  fi

  if [[ -z "$runs" ]]; then
    echo "  ${C_DIM}no active or unreviewed runs${C_RESET}"
    return
  fi

  printf "${C_BOLD}%-10s %-10s %-15s %-25s %s${C_RESET}\n" "Run ID" "Job ID" "Status" "Started" "Exit"
  while IFS=$'\x1e' read -r rid cid rstatus started ecode; do
    [[ -n "$rid" ]] || continue
    local sc=""
    [[ "$rstatus" == "active" ]] && sc="${C_GREEN}" || sc="${C_YELLOW}"
    printf "%-10s %-10s ${sc}%-15s${C_RESET} %-25s %s\n" "$rid" "$cid" "$rstatus" "$started" "$ecode"
  done <<< "$runs"
}

cmd_cron_enable() {
  local cron_id="${1:-}"
  [[ -n "$cron_id" ]] || die "usage: cloard-board cron enable <id>"
  cron_job_exists "$cron_id" || die "cron job not found: ${cron_id}"

  update_cron_job_field_raw "$cron_id" "enabled" "true"

  local plist_path
  plist_path=$(cron_job_field "$cron_id" "plist_path")
  if [[ -n "$plist_path" && -f "$plist_path" ]]; then
    launchctl load "$plist_path" 2>/dev/null || warn "failed to load plist"
  fi
  ok "enabled cron job ${cron_id}"
}

cmd_cron_disable() {
  local cron_id="${1:-}"
  [[ -n "$cron_id" ]] || die "usage: cloard-board cron disable <id>"
  cron_job_exists "$cron_id" || die "cron job not found: ${cron_id}"

  local plist_path
  plist_path=$(cron_job_field "$cron_id" "plist_path")
  if [[ -n "$plist_path" && -f "$plist_path" ]]; then
    launchctl unload "$plist_path" 2>/dev/null || warn "failed to unload plist"
  fi

  update_cron_job_field_raw "$cron_id" "enabled" "false"
  ok "disabled cron job ${cron_id}"
}

cmd_cron_remove() {
  local cron_id="${1:-}"
  [[ -n "$cron_id" ]] || die "usage: cloard-board cron remove <id>"
  cron_job_exists "$cron_id" || die "cron job not found: ${cron_id}"

  local name
  name=$(cron_job_field "$cron_id" "name")

  printf "${C_RED}Delete cron job '${name}' (${cron_id})? Type DELETE to confirm: ${C_RESET}"
  local confirm=""
  read -r confirm
  [[ "$confirm" == "DELETE" ]] || { echo "cancelled"; return 0; }

  # Unload plist
  local plist_path
  plist_path=$(cron_job_field "$cron_id" "plist_path")
  if [[ -n "$plist_path" && -f "$plist_path" ]]; then
    launchctl unload "$plist_path" 2>/dev/null || true
    rm -f "$plist_path"
  fi

  # Remove from state
  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.cron.XXXXXX")
  jq --arg id "$cron_id" '
    .cron_jobs = [.cron_jobs[] | select(.id != $id)] |
    .cron_runs = [.cron_runs[] | select(.cron_job_id != $id)]
  ' "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
  ok "removed cron job ${cron_id} '${name}'"
}

cmd_cron_review() {
  local run_id="${1:-}"
  [[ -n "$run_id" ]] || die "usage: cloard-board cron review <run-id>"

  local rstatus
  rstatus=$(cron_run_field "$run_id" "status")
  [[ -n "$rstatus" ]] || die "run not found: ${run_id}"
  [[ "$rstatus" == "needs_review" ]] || die "run ${run_id} is not in needs_review status (current: ${rstatus})"

  update_cron_run_field "$run_id" "status" "reviewed"
  ok "marked run ${run_id} as reviewed"
}

cmd_cron_migrate() {
  info "scanning for Claude-invoking LaunchAgents to migrate..."
  local found=0
  while IFS=$'\x1e' read -r label ppath wdir sdesc sjson; do
    [[ -n "$label" ]] || continue
    found=$((found + 1))

    echo ""
    echo "  ${C_BOLD}${label}${C_RESET}"
    echo "  plist: ${ppath}"
    echo "  schedule: ${sdesc}"

    printf "  ${C_CYAN}Migrate this job? [Y/n]: ${C_RESET}"
    local ans=""
    read -r ans
    [[ "$ans" =~ ^[nN]$ ]] && continue

    # Extract name from label (last component)
    local jname
    jname=$(echo "$label" | sed 's/.*\.//')

    # Extract Claude command from the referenced script
    local pjson claude_cmd="" env_vars="{}"
    pjson=$(plutil -convert json -o - "$ppath" 2>/dev/null) || continue
    local script_path
    script_path=$(echo "$pjson" | jq -r '.ProgramArguments // [] | if length > 1 then .[1] else "" end')
    if [[ -n "$script_path" && -f "$script_path" ]]; then
      # Find the claude command line in the script
      claude_cmd=$(grep -E '^\s*(env [^|]*)?(\$CLAUDE_BIN|claude)\b' "$script_path" 2>/dev/null | head -1 | sed 's/^\s*//')
      # Replace $CLAUDE_BIN with "claude"
      claude_cmd=$(echo "$claude_cmd" | sed 's|\$CLAUDE_BIN|claude|g; s|env -u [A-Z_]* ||g; s|>> .*||; s|2>&1||; s|\s*$||')
    fi

    if [[ -z "$claude_cmd" ]]; then
      printf "  ${C_CYAN}Could not auto-extract Claude command. Enter it manually: ${C_RESET}"
      read -r claude_cmd
      [[ -n "$claude_cmd" ]] || { warn "skipping (no command)"; continue; }
    else
      echo "  ${C_DIM}detected command: ${claude_cmd}${C_RESET}"
    fi

    # Extract env vars from plist
    env_vars=$(echo "$pjson" | jq -c '.EnvironmentVariables // {}')

    # Determine schedule type
    local schedule_type="daily"
    local sci_type
    sci_type=$(echo "$sjson" | jq -r 'type' 2>/dev/null) || sci_type="null"
    if [[ "$sci_type" == "array" ]]; then
      local count
      count=$(echo "$sjson" | jq 'length')
      if [[ $count -gt 1 ]]; then
        schedule_type="hourly"
      fi
    fi

    # Create cron job in state
    local cron_id
    cron_id=$(_next_cron_id)

    _lock_state || continue
    local tmp
    tmp=$(mktemp "${GLOBAL_DIR}/.cron.XXXXXX")
    jq --arg id "$cron_id" --arg name "$jname" --arg wdir "$wdir" \
      --arg cmd "$claude_cmd" --arg stype "$schedule_type" --arg sdesc "$sdesc" \
      --argjson sraw "$sjson" --argjson env "$env_vars" --arg now "$(now_iso)" \
      --arg old_label "$label" '
      .cron_jobs += [{
        id: $id, label: $old_label, name: $name, plist_path: "",
        working_dir: $wdir, claude_command: $cmd,
        schedule_type: $stype, schedule_desc: $sdesc, schedule_raw: $sraw,
        enabled: true, created_at: $now, env_vars: $env
      }]
    ' "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
    _unlock_state

    # Generate new plist
    local new_plist
    new_plist=$(_generate_plist "$cron_id")

    # Unload old, load new
    launchctl unload "$ppath" 2>/dev/null || true
    launchctl load "$new_plist" 2>/dev/null || warn "failed to load new plist"

    # Archive old plist
    local date_suffix
    date_suffix=$(date +%Y%m%d)
    mv "$ppath" "${ppath}.migrated-${date_suffix}" 2>/dev/null || true

    ok "migrated '${jname}' as ${cron_id} (old plist archived)"
  done

  if [[ $found -eq 0 ]]; then
    echo "  ${C_DIM}no Claude-invoking LaunchAgents found to migrate${C_RESET}"
  fi
}

