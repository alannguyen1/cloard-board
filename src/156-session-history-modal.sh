# ── Session History Modal ─────────────────────────────────────────────────────
# Centered overlay modal for browsing and switching between a task's past
# Claude sessions. Follows the 155-modal.sh pattern (stty, move_to, box chars).

# Show the session history modal for a given task. Returns 0 if user switched
# session, 1 on cancel / nothing to show.
# Accesses _task_title, _task_repo via dynamic scoping from cmd__dash_loop.
_session_history_modal() {
  local task_id="$1"

  # Gather history UIDs (newline-delimited, most recent first)
  local hist_raw
  hist_raw=$(get_session_history "$task_id")
  if [[ -z "$hist_raw" ]]; then
    _session_history_modal_empty "$task_id"
    return 1
  fi

  local -a sh_uids=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && sh_uids+=("$line")
  done <<< "$hist_raw"

  if [[ ${#sh_uids[@]} -le 1 ]]; then
    _session_history_modal_empty "$task_id"
    return 1
  fi

  # Resolve repo name and collect mtimes
  local sh_repo="${_task_repo[$task_id]:-}"
  local -a sh_mtimes=()
  local idx
  for (( idx=0; idx<${#sh_uids[@]}; idx++ )); do
    sh_mtimes+=("$(_session_file_mtime "${sh_uids[$idx]}" "$sh_repo")")
  done

  # Modal state
  local sh_cursor=0
  local sh_title="${_task_title[$task_id]:-$task_id}"

  stty -echo raw

  local ch result=1
  _session_history_render
  while true; do
    read -rk1 ch 2>/dev/null || { stty echo -raw; return 1; }
    case "$ch" in
      $'\e')
        local seq1=""
        read -rk1 -t 0.05 seq1 2>/dev/null || true
        if [[ -z "$seq1" ]]; then
          # Plain Esc: cancel
          break
        elif [[ "$seq1" == "[" ]]; then
          local seq2=""
          read -rk1 -t 0.05 seq2 2>/dev/null || true
          case "$seq2" in
            A) # Up arrow
              [[ $sh_cursor -gt 0 ]] && sh_cursor=$((sh_cursor - 1))
              ;;
            B) # Down arrow
              [[ $sh_cursor -lt $((${#sh_uids[@]} - 1)) ]] && sh_cursor=$((sh_cursor + 1))
              ;;
          esac
        fi
        ;;
      j)
        [[ $sh_cursor -lt $((${#sh_uids[@]} - 1)) ]] && sh_cursor=$((sh_cursor + 1))
        ;;
      k)
        [[ $sh_cursor -gt 0 ]] && sh_cursor=$((sh_cursor - 1))
        ;;
      $'\n'|$'\r')
        # Switch to selected session
        set_session_uid_from_history "$task_id" "${sh_uids[$sh_cursor]}"
        result=0
        break
        ;;
      $'\x03')
        # Ctrl-C: cancel
        break
        ;;
      q)
        break
        ;;
    esac
    _session_history_render
  done

  stty echo -raw
  return $result
}

# Render the "no history" info box, wait for Esc
_session_history_modal_empty() {
  local task_id="$1"
  local m_cols m_rows
  m_cols=$(tput cols)
  m_rows=$(tput lines)
  local m_width=$(( m_cols - 10 ))
  [[ $m_width -lt 40 ]] && m_width=40
  [[ $m_width -gt 56 ]] && m_width=56
  local m_inner=$(( m_width - 2 ))
  local m_height=7
  local m_top=$(( (m_rows - m_height) / 2 ))
  [[ $m_top -lt 1 ]] && m_top=1
  local m_left=$(( (m_cols - m_width) / 2 + 1 ))

  local hbar="" i
  for (( i=0; i<m_inner; i++ )); do hbar+="═"; done
  local title=" Session History "
  local hbar_left="═══"
  local hbar_right_len=$(( m_inner - 3 - ${#title} ))
  local hbar_right=""
  for (( i=0; i<hbar_right_len; i++ )); do hbar_right+="═"; done
  local blank_inner=""
  printf -v blank_inner "%-${m_inner}s" ""

  move_to "$m_top" "$m_left"
  printf "╔%s%s%s╗" "$hbar_left" "$title" "$hbar_right"
  move_to "$((m_top + 1))" "$m_left"
  printf "║%s║" "$blank_inner"
  move_to "$((m_top + 2))" "$m_left"
  printf "║  %-$((m_inner - 2))s║" "No session history for ${task_id}."
  move_to "$((m_top + 3))" "$m_left"
  printf "║  %-$((m_inner - 2))s║" "Only one session (or none) recorded."
  move_to "$((m_top + 4))" "$m_left"
  printf "║%s║" "$blank_inner"
  move_to "$((m_top + 5))" "$m_left"
  printf "║  ${C_DIM}%-$((m_inner - 2))s${C_RESET}║" "Esc: close"
  move_to "$((m_top + 6))" "$m_left"
  printf "╚%s╝" "$hbar"

  stty -echo raw
  local ch
  while true; do
    read -rk1 ch 2>/dev/null || break
    if [[ "$ch" == $'\e' ]]; then
      local discard
      while read -rk1 -t 0.05 discard 2>/dev/null; do :; done
      break
    elif [[ "$ch" == $'\x03' || "$ch" == "q" ]]; then
      break
    fi
  done
  stty echo -raw
}

# Render the session history list modal
# Uses dynamic-scoped: sh_uids, sh_mtimes, sh_cursor, sh_title, task_id
_session_history_render() {
  local m_cols m_rows
  m_cols=$(tput cols)
  m_rows=$(tput lines)
  local m_width=$(( m_cols - 10 ))
  [[ $m_width -lt 40 ]] && m_width=40
  [[ $m_width -gt 60 ]] && m_width=60
  local m_inner=$(( m_width - 2 ))

  # Height: top border + blank + task line + blank + items + blank + footer1 + footer2 + bottom border
  local item_count=${#sh_uids[@]}
  local m_height=$(( 1 + 1 + 1 + 1 + item_count + 1 + 1 + 1 + 1 ))
  local m_top=$(( (m_rows - m_height) / 2 ))
  [[ $m_top -lt 1 ]] && m_top=1
  local m_left=$(( (m_cols - m_width) / 2 + 1 ))

  # Build horizontal bars
  local hbar="" i
  for (( i=0; i<m_inner; i++ )); do hbar+="═"; done
  local title=" Session History "
  local hbar_left="═══"
  local hbar_right_len=$(( m_inner - 3 - ${#title} ))
  local hbar_right=""
  for (( i=0; i<hbar_right_len; i++ )); do hbar_right+="═"; done
  local blank_inner=""
  printf -v blank_inner "%-${m_inner}s" ""

  local row=$m_top

  # Top border
  move_to "$row" "$m_left"
  printf "╔%s%s%s╗" "$hbar_left" "$title" "$hbar_right"
  row=$((row + 1))

  # Blank line
  move_to "$row" "$m_left"
  printf "║%s║" "$blank_inner"
  row=$((row + 1))

  # Task ID + title line
  local task_line="${task_id}: ${sh_title}"
  task_line=$(trunc "$task_line" $((m_inner - 4)))
  move_to "$row" "$m_left"
  printf "║  ${C_BOLD}%-$((m_inner - 2))s${C_RESET}║" "$task_line"
  row=$((row + 1))

  # Blank line
  move_to "$row" "$m_left"
  printf "║%s║" "$blank_inner"
  row=$((row + 1))

  # Session list
  local si
  for (( si=0; si<item_count; si++ )); do
    local uid_short="${sh_uids[$si]:0:8}"
    local mtime="${sh_mtimes[$si]}"
    local num=$((si + 1))
    local prefix="   "
    [[ $si -eq $sh_cursor ]] && prefix=" > "
    local suffix=""
    [[ $si -eq 0 ]] && suffix=" (current)"
    local entry_text="${prefix}${num}. ${uid_short}  ${mtime}${suffix}"
    entry_text=$(trunc "$entry_text" $((m_inner - 2)))

    move_to "$row" "$m_left"
    if [[ $si -eq $sh_cursor ]]; then
      printf "║${C_BOLD}${C_CYAN}  %-$((m_inner - 2))s${C_RESET}║" "$entry_text"
    else
      printf "║  %-$((m_inner - 2))s║" "$entry_text"
    fi
    row=$((row + 1))
  done

  # Blank line
  move_to "$row" "$m_left"
  printf "║%s║" "$blank_inner"
  row=$((row + 1))

  # Footer hints
  local footer1="  j/k: navigate  Enter: switch"
  footer1=$(trunc "$footer1" "$m_inner")
  move_to "$row" "$m_left"
  printf "║${C_DIM}%-${m_inner}s${C_RESET}║" "$footer1"
  row=$((row + 1))

  local footer2="  Esc: cancel"
  footer2=$(trunc "$footer2" "$m_inner")
  move_to "$row" "$m_left"
  printf "║${C_DIM}%-${m_inner}s${C_RESET}║" "$footer2"
  row=$((row + 1))

  # Bottom border
  move_to "$row" "$m_left"
  printf "╚%s╝" "$hbar"
}

# Get the modification time of a session's .jsonl file
# Returns "file missing" if not found
_session_file_mtime() {
  local uid="$1" repo_name="$2"
  [[ -n "$repo_name" ]] || { echo "file missing"; return; }

  local rpath
  rpath=$(repo_path "$repo_name")
  [[ -n "$rpath" ]] || { echo "file missing"; return; }

  local encoded="${rpath//\//-}"
  encoded="${encoded// /-}"
  local session_file="$HOME/.claude/projects/${encoded}/${uid}.jsonl"

  if [[ -f "$session_file" ]]; then
    stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$session_file" 2>/dev/null || echo "unknown"
  else
    echo "file missing"
  fi
}
