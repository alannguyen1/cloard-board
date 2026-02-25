# ── Cron: plist discovery ─────────────────────────────────────────────────────

# Scan ~/Library/LaunchAgents for plists that invoke Claude.
# Outputs record-separator delimited lines: label\x1epath\x1eworking_dir\x1eschedule_desc\x1eschedule_json
_scan_launch_agents() {
  local plist_dir="$HOME/Library/LaunchAgents"
  [[ -d "$plist_dir" ]] || return 0

  local plist
  for plist in "$plist_dir"/*.plist; do
    [[ -f "$plist" ]] || continue

    local pjson
    pjson=$(plutil -convert json -o - "$plist" 2>/dev/null) || continue

    local label prog_args
    label=$(echo "$pjson" | jq -r '.Label // ""')
    prog_args=$(echo "$pjson" | jq -r '.ProgramArguments // [] | join(" ")')

    # Check if ProgramArguments directly contains "claude"
    local has_claude=false
    if echo "$prog_args" | grep -qi 'claude'; then
      has_claude=true
    fi

    # Level 2: if args invoke a shell script, check that script for "claude"
    if ! $has_claude; then
      local script_path
      script_path=$(echo "$pjson" | jq -r '.ProgramArguments // [] | if length > 1 then .[1] else "" end')
      if [[ -n "$script_path" && -f "$script_path" ]]; then
        if grep -qi 'claude' "$script_path" 2>/dev/null; then
          has_claude=true
        fi
      fi
    fi

    $has_claude || continue

    # Skip plists already managed by cloard-board
    if [[ "$label" == com.cloard-board.* ]]; then
      continue
    fi

    local working_dir schedule_desc schedule_json
    working_dir=$(echo "$pjson" | jq -r '.WorkingDirectory // ""')

    # Parse schedule
    local sci_type
    sci_type=$(echo "$pjson" | jq -r '.StartCalendarInterval | type')
    if [[ "$sci_type" == "object" ]]; then
      local hour minute
      hour=$(echo "$pjson" | jq -r '.StartCalendarInterval.Hour // "*"')
      minute=$(echo "$pjson" | jq -r '.StartCalendarInterval.Minute // 0')
      schedule_desc="Daily at $(printf '%02d:%02d' "$hour" "$minute")"
      schedule_json=$(echo "$pjson" | jq -c '.StartCalendarInterval')
    elif [[ "$sci_type" == "array" ]]; then
      local count
      count=$(echo "$pjson" | jq '.StartCalendarInterval | length')
      local first_hour first_minute last_hour
      first_hour=$(echo "$pjson" | jq -r '.StartCalendarInterval[0].Hour // "*"')
      first_minute=$(echo "$pjson" | jq -r '.StartCalendarInterval[0].Minute // 0')
      last_hour=$(echo "$pjson" | jq -r '.StartCalendarInterval[-1].Hour // "*"')
      schedule_desc="Every hour ${first_hour}:$(printf '%02d' "$first_minute")-${last_hour}:$(printf '%02d' "$first_minute") (${count} slots)"
      schedule_json=$(echo "$pjson" | jq -c '.StartCalendarInterval')
    else
      schedule_desc="Unknown"
      schedule_json="null"
    fi

    printf '%s\x1e%s\x1e%s\x1e%s\x1e%s\n' "$label" "$plist" "$working_dir" "$schedule_desc" "$schedule_json"
  done
}

# Archive cron runs older than 24h that are still needs_review
_archive_stale_cron_runs() {
  local cutoff
  cutoff=$(date -u -v-24H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '24 hours ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || return 0

  local stale_count
  stale_count=$(jq -r --arg cutoff "$cutoff" '
    [.cron_runs[] | select(.status == "needs_review" and .completed_at != null and .completed_at < $cutoff)] | length
  ' "$GLOBAL_STATE" 2>/dev/null) || return 0
  [[ "$stale_count" -gt 0 ]] || return 0

  _lock_state || return 1
  local tmp
  tmp=$(mktemp "${GLOBAL_DIR}/.cron.XXXXXX")
  jq --arg cutoff "$cutoff" '
    .cron_runs = [.cron_runs[] |
      if .status == "needs_review" and .completed_at != null and .completed_at < $cutoff then
        .status = "archived"
      else . end
    ]
  ' "$GLOBAL_STATE" > "$tmp" && mv "$tmp" "$GLOBAL_STATE"
  _unlock_state
}

# Install cloard-board binary to ~/.cloard-board/bin/ (outside TCC-protected dirs)
# launchd jobs cannot access ~/Documents, ~/Desktop, ~/Downloads on macOS
_install_cron_binary() {
  local bin_dir="$GLOBAL_DIR/bin"
  local installed="$bin_dir/cloard-board"
  mkdir -p "$bin_dir"
  if [[ ! -f "$installed" ]] || ! diff -q "$SCRIPT_PATH" "$installed" >/dev/null 2>&1; then
    cp "$SCRIPT_PATH" "$installed"
    chmod +x "$installed"
    info "installed cloard-board to $installed"
  fi
  echo "$installed"
}

# Generate a launchd plist for a cron job
_generate_plist() {
  local cron_id="$1"
  local job_name working_dir claude_cmd schedule_type schedule_raw env_json
  job_name=$(cron_job_field "$cron_id" "name")
  working_dir=$(cron_job_field "$cron_id" "working_dir")
  claude_cmd=$(cron_job_field "$cron_id" "claude_command")
  schedule_type=$(cron_job_field "$cron_id" "schedule_type")
  schedule_raw=$(jq -r --arg id "$cron_id" '.cron_jobs[] | select(.id == $id) | .schedule_raw' "$GLOBAL_STATE")
  env_json=$(jq -r --arg id "$cron_id" '.cron_jobs[] | select(.id == $id) | .env_vars // {}' "$GLOBAL_STATE")

  local plist_label="com.cloard-board.${job_name}"
  local plist_path="$HOME/Library/LaunchAgents/${plist_label}.plist"
  local log_dir="$GLOBAL_DIR/logs"
  mkdir -p "$log_dir"

  # Install binary outside TCC-protected dirs for launchd access
  local script_path
  script_path=$(_install_cron_binary)

  # Build environment variables XML
  # Always include PATH (launchd uses minimal PATH) and HOME as defaults;
  # user-provided env_vars override these if present
  local launchd_path="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${HOME}/.local/bin"
  local has_user_path=false has_user_home=false
  if [[ "$env_json" != "{}" && "$env_json" != "null" ]]; then
    echo "$env_json" | jq -e '.PATH' >/dev/null 2>&1 && has_user_path=true
    echo "$env_json" | jq -e '.HOME' >/dev/null 2>&1 && has_user_home=true
  fi

  local env_xml="    <key>EnvironmentVariables</key>
    <dict>"
  # Add HOME default if user didn't provide one
  if ! $has_user_home; then
    env_xml="${env_xml}
        <key>HOME</key>
        <string>$(_xml_escape "$HOME")</string>"
  fi
  # Add PATH default if user didn't provide one
  if ! $has_user_path; then
    env_xml="${env_xml}
        <key>PATH</key>
        <string>$(_xml_escape "$launchd_path")</string>"
  fi
  # Add all user-provided env vars
  if [[ "$env_json" != "{}" && "$env_json" != "null" ]]; then
    while IFS=$'\x1e' read -r ekey eval; do
      [[ -n "$ekey" ]] || continue
      if [[ ! "$ekey" =~ ^[A-Za-z_][A-Za-z_0-9]*$ ]]; then
        warn "skipping invalid env var name: ${ekey}"
        continue
      fi
      env_xml="${env_xml}
        <key>$(_xml_escape "$ekey")</key>
        <string>$(_xml_escape "$eval")</string>"
    done < <(echo "$env_json" | jq -r 'to_entries[] | [.key, .value] | join("\u001e")')
  fi
  env_xml="${env_xml}
    </dict>"

  # Build schedule XML
  local schedule_xml=""
  local sci_type
  sci_type=$(echo "$schedule_raw" | jq -r 'type' 2>/dev/null) || sci_type="null"
  if [[ "$sci_type" == "object" ]]; then
    schedule_xml="    <key>StartCalendarInterval</key>
    <dict>"
    while IFS=$'\x1e' read -r skey sval; do
      [[ -n "$skey" ]] || continue
      if [[ ! "$sval" =~ ^[0-9]+$ ]]; then
        warn "skipping non-integer schedule value: ${skey}=${sval}"
        continue
      fi
      schedule_xml="${schedule_xml}
        <key>$(_xml_escape "$skey")</key>
        <integer>${sval}</integer>"
    done < <(echo "$schedule_raw" | jq -r 'to_entries[] | [.key, (.value | tostring)] | join("\u001e")')
    schedule_xml="${schedule_xml}
    </dict>"
  elif [[ "$sci_type" == "array" ]]; then
    schedule_xml="    <key>StartCalendarInterval</key>
    <array>"
    while IFS= read -r entry; do
      schedule_xml="${schedule_xml}
        <dict>"
      while IFS=$'\x1e' read -r skey sval; do
        [[ -n "$skey" ]] || continue
        if [[ ! "$sval" =~ ^[0-9]+$ ]]; then
          warn "skipping non-integer schedule value: ${skey}=${sval}"
          continue
        fi
        schedule_xml="${schedule_xml}
            <key>$(_xml_escape "$skey")</key>
            <integer>${sval}</integer>"
      done < <(echo "$entry" | jq -r 'to_entries[] | [.key, (.value | tostring)] | join("\u001e")')
      schedule_xml="${schedule_xml}
        </dict>"
    done < <(echo "$schedule_raw" | jq -c '.[]')
    schedule_xml="${schedule_xml}
    </array>"
  fi

  # Pre-escape values for XML interpolation in the plist
  local esc_label esc_script esc_cron_id esc_working_dir esc_log_dir esc_job_name
  esc_label=$(_xml_escape "$plist_label")
  esc_script=$(_xml_escape "$script_path")
  esc_cron_id=$(_xml_escape "$cron_id")
  esc_working_dir=$(_xml_escape "$working_dir")
  esc_log_dir=$(_xml_escape "$log_dir")
  esc_job_name=$(_xml_escape "$job_name")

  cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${esc_label}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${esc_script}</string>
        <string>cron-exec</string>
        <string>${esc_cron_id}</string>
    </array>

${env_xml:+$env_xml

}    <key>WorkingDirectory</key>
    <string>${esc_working_dir}</string>

${schedule_xml}

    <key>StandardOutPath</key>
    <string>${esc_log_dir}/${esc_job_name}.log</string>

    <key>StandardErrorPath</key>
    <string>${esc_log_dir}/${esc_job_name}-error.log</string>
</dict>
</plist>
PLIST

  # Store plist path in state
  update_cron_job_field "$cron_id" "plist_path" "$plist_path"
  update_cron_job_field "$cron_id" "label" "$plist_label"
  echo "$plist_path"
}

