# ── Unified Create Modal ──────────────────────────────────────────────────────
# Centered overlay modal for creating tasks or cron jobs from the dashboard.
# All _modal_* functions access _mf_* state via zsh dynamic scoping;
# the caller (c) handler in cmd__dash_loop) declares these as local.
#
# Focus indices:
#   0 = Type toggle (Task/Cron)
#   1 = Repo dropdown
#   2 = Title (task) / Name (cron)
#   3 = Worktree toggle (task) / Schedule dropdown (cron)
#   4 = Prompt (task) / Schedule sub-field 1 (cron)
#   5 = Schedule sub-field 2 (cron: hourly/interval only)
#   6 = Schedule sub-field 3 (cron: hourly/interval only)
#   7 = Prompt (cron)

# Open the create modal. Returns 0 on submit, 1 on cancel.
# Expects _mf_* variables to be declared local in the calling scope.
# Reads filter_mode, _repo_names, _repo_types, _repo_stale via dynamic scoping.
_modal_open() {
  # Build filtered repo list (exclude stale)
  _mf_repo_list=()
  local rn
  for rn in "${_repo_names[@]}"; do
    [[ -n "${_repo_stale[$rn]:-}" ]] && continue
    _mf_repo_list+=("$rn")
  done

  # No repos: show help and wait for Esc
  if [[ ${#_mf_repo_list[@]} -eq 0 ]]; then
    _modal_render_no_repos
    return 1
  fi

  # Defaults
  _mf_title=""
  _mf_prompt=""
  _mf_worktree=0
  _mf_dropdown_open=0
  _mf_dropdown_idx=0
  _mf_repo_readonly=0
  _mf_wt_locked=0
  _mf_repo_hint=""
  _mf_repo=""
  # Cron defaults (type is NOT reset; caller pre-sets it for context-awareness)
  _mf_name=""
  _mf_sched_type=0
  _mf_sched_dd_open=0
  _mf_sched_dd_idx=0
  _mf_sched_time=""
  _mf_sched_start_h=""
  _mf_sched_end_h=""
  _mf_sched_at_min=""
  _mf_sched_interval=""

  # Pre-fill logic
  if [[ "$filter_mode" != "all" && -z "${_repo_stale[$filter_mode]:-}" ]]; then
    _mf_repo="$filter_mode"
    _mf_repo_readonly=1
    _mf_focus=2
  elif [[ ${#_mf_repo_list[@]} -eq 1 ]]; then
    _mf_repo="${_mf_repo_list[0]}"
    _mf_repo_readonly=1
    _mf_repo_hint="(only repo)"
    _mf_focus=2
  else
    _mf_focus=0
  fi

  # Lock worktree for dir repos
  if [[ -n "$_mf_repo" ]]; then
    if [[ "${_repo_types[$_mf_repo]:-git}" == "dir" ]]; then
      _mf_wt_locked=1
      _mf_worktree=0
    fi
  fi

  _modal_input_loop
}

# Render the "no repos" help modal, wait for Esc
_modal_render_no_repos() {
  local m_cols m_rows
  m_cols=$(tput cols)
  m_rows=$(tput lines)
  local m_width=$(( m_cols - 10 ))
  [[ $m_width -lt 40 ]] && m_width=40
  [[ $m_width -gt 60 ]] && m_width=60
  local m_inner=$(( m_width - 2 ))
  local m_height=7
  local m_top=$(( (m_rows - m_height) / 2 ))
  [[ $m_top -lt 1 ]] && m_top=1
  local m_left=$(( (m_cols - m_width) / 2 + 1 ))

  # Build borders
  local hbar="" i
  for (( i=0; i<m_inner; i++ )); do hbar+="═"; done
  local title=" New Task "
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
  printf "║  %-$((m_inner - 2))s║" "No repos registered."
  move_to "$((m_top + 3))" "$m_left"
  printf "║  %-$((m_inner - 2))s║" "Run: cloard-board repo add <path>"
  move_to "$((m_top + 4))" "$m_left"
  printf "║%s║" "$blank_inner"
  move_to "$((m_top + 5))" "$m_left"
  printf "║  ${C_DIM}%-$((m_inner - 2))s${C_RESET}║" "Esc: close"
  move_to "$((m_top + 6))" "$m_left"
  printf "╚%s╝" "$hbar"

  # Wait for Esc
  stty -echo raw
  local ch
  while true; do
    read -rk1 ch 2>/dev/null || break
    if [[ "$ch" == $'\e' ]]; then
      local discard
      while read -rk1 -t 0.05 discard 2>/dev/null; do :; done
      break
    fi
  done
  stty echo -raw
}

# Input loop for the modal. Returns 0 on submit, 1 on cancel.
_modal_input_loop() {
  stty -echo raw
  _modal_render

  local ch prompt_idx
  while true; do
    read -rk1 ch 2>/dev/null || { stty echo -raw; return 1; }
    [[ $_mf_type -eq 0 ]] && prompt_idx=4 || prompt_idx=7
    case "$ch" in
      $'\e')
        # Check for escape sequence (arrow keys, shift-tab)
        local seq1="" seq2=""
        read -rk1 -t 0.05 seq1 2>/dev/null || true
        if [[ -z "$seq1" ]]; then
          # Plain Esc
          if [[ $_mf_dropdown_open -eq 1 ]]; then
            _mf_dropdown_open=0
          elif [[ $_mf_sched_dd_open -eq 1 ]]; then
            _mf_sched_dd_open=0
          else
            stty echo -raw
            return 1
          fi
        elif [[ "$seq1" == "[" ]]; then
          read -rk1 -t 0.05 seq2 2>/dev/null || true
          case "$seq2" in
            A) # Up arrow
              if [[ $_mf_dropdown_open -eq 1 ]]; then
                [[ $_mf_dropdown_idx -gt 0 ]] && _mf_dropdown_idx=$((_mf_dropdown_idx - 1))
              elif [[ $_mf_sched_dd_open -eq 1 ]]; then
                [[ $_mf_sched_dd_idx -gt 0 ]] && _mf_sched_dd_idx=$((_mf_sched_dd_idx - 1))
              fi
              ;;
            B) # Down arrow
              if [[ $_mf_dropdown_open -eq 1 ]]; then
                local max_dd=$(( ${#_mf_repo_list[@]} - 1 ))
                [[ $_mf_dropdown_idx -lt $max_dd ]] && _mf_dropdown_idx=$((_mf_dropdown_idx + 1))
              elif [[ $_mf_sched_dd_open -eq 1 ]]; then
                [[ $_mf_sched_dd_idx -lt 3 ]] && _mf_sched_dd_idx=$((_mf_sched_dd_idx + 1))
              fi
              ;;
            C|D) # Left/Right arrow
              if [[ $_mf_focus -eq 0 ]]; then
                _modal_toggle_type
              elif [[ $_mf_focus -eq 3 && $_mf_type -eq 0 && $_mf_wt_locked -eq 0 ]]; then
                _mf_worktree=$(( 1 - _mf_worktree ))
              fi
              ;;
            Z) # Shift-Tab
              _modal_handle_shift_tab
              ;;
          esac
        fi
        ;;
      $'\t')
        if [[ $_mf_dropdown_open -eq 1 ]]; then
          _modal_select_dropdown
        elif [[ $_mf_sched_dd_open -eq 1 ]]; then
          _modal_select_schedule_dropdown
        else
          _modal_handle_tab
        fi
        ;;
      $'\n'|$'\r')
        if [[ $_mf_dropdown_open -eq 1 ]]; then
          _modal_select_dropdown
        elif [[ $_mf_sched_dd_open -eq 1 ]]; then
          _modal_select_schedule_dropdown
        elif [[ $_mf_focus -eq 1 && $_mf_repo_readonly -eq 0 ]]; then
          _mf_dropdown_open=1
          _mf_sched_dd_open=0
          _mf_dropdown_idx=0
        elif [[ $_mf_focus -eq 3 && $_mf_type -eq 1 ]]; then
          _mf_sched_dd_open=1
          _mf_dropdown_open=0
          _mf_sched_dd_idx=$_mf_sched_type
        elif [[ -n "$_mf_repo" ]]; then
          # Submit form (only if repo selected)
          stty echo -raw
          return 0
        fi
        ;;
      ' ')
        if [[ $_mf_focus -eq 0 ]]; then
          _modal_toggle_type
        elif [[ $_mf_focus -eq 3 && $_mf_type -eq 0 && $_mf_wt_locked -eq 0 ]]; then
          _mf_worktree=$(( 1 - _mf_worktree ))
        elif [[ $_mf_focus -eq 2 ]]; then
          if [[ $_mf_type -eq 0 ]]; then
            _mf_title+=" "
          else
            _mf_name+=" "
          fi
        elif [[ $_mf_focus -eq $prompt_idx ]]; then
          _mf_prompt+=" "
        fi
        ;;
      $'\x03')
        # Ctrl-C: cancel modal
        stty echo -raw
        return 1
        ;;
      $'\x7f'|$'\b')
        _modal_handle_backspace
        ;;
      $'\x15')
        _modal_handle_ctrl_u
        ;;
      $'\x17')
        _modal_handle_ctrl_w
        ;;
      *)
        if [[ $_mf_focus -eq 2 ]]; then
          if [[ $_mf_type -eq 0 ]]; then
            _mf_title+="$ch"
          else
            _mf_name+="$ch"
          fi
        elif [[ $_mf_focus -eq $prompt_idx ]]; then
          _mf_prompt+="$ch"
        elif [[ $_mf_type -eq 1 && $_mf_focus -ge 4 && $_mf_focus -le 6 ]]; then
          _modal_sched_char_input "$ch"
        fi
        ;;
    esac
    _modal_render
  done
}

# Toggle type and reset type-specific fields (preserve prompt + repo)
_modal_toggle_type() {
  _mf_type=$(( 1 - _mf_type ))
  _mf_title=""
  _mf_name=""
  _mf_sched_type=0
  _mf_sched_dd_open=0
  _mf_sched_dd_idx=0
  _mf_sched_time=""
  _mf_sched_start_h=""
  _mf_sched_end_h=""
  _mf_sched_at_min=""
  _mf_sched_interval=""
  _mf_worktree=0
  if [[ -n "$_mf_repo" && "${_repo_types[$_mf_repo]:-git}" == "dir" ]]; then
    _mf_wt_locked=1
  else
    _mf_wt_locked=0
  fi
}

# Schedule sub-field character input
_modal_sched_char_input() {
  local ch="$1"
  case $_mf_sched_type in
    0|1)  # Daily/Weekdays: focus 4 = time (HH:MM)
      if [[ $_mf_focus -eq 4 && "$ch" =~ [0-9:] ]]; then
        _mf_sched_time+="$ch"
      fi
      ;;
    2)  # Hourly
      if [[ "$ch" =~ [0-9] ]]; then
        case $_mf_focus in
          4) _mf_sched_start_h+="$ch" ;;
          5) _mf_sched_end_h+="$ch" ;;
          6) _mf_sched_at_min+="$ch" ;;
        esac
      fi
      ;;
    3)  # Interval
      if [[ "$ch" =~ [0-9] ]]; then
        case $_mf_focus in
          4) _mf_sched_start_h+="$ch" ;;
          5) _mf_sched_end_h+="$ch" ;;
          6) _mf_sched_interval+="$ch" ;;
        esac
      fi
      ;;
  esac
}

# Tab: advance focus, skipping read-only/locked/irrelevant fields
_modal_handle_tab() {
  local max_focus
  [[ $_mf_type -eq 0 ]] && max_focus=4 || max_focus=7
  local next=$(( _mf_focus + 1 ))
  [[ $next -gt $max_focus ]] && next=0
  # Skip repo if readonly
  [[ $next -eq 1 && $_mf_repo_readonly -eq 1 ]] && next=2
  # Task mode: skip worktree if locked
  if [[ $_mf_type -eq 0 && $next -eq 3 && $_mf_wt_locked -eq 1 ]]; then
    next=4
  fi
  # Cron mode: skip sub-fields 5,6 for daily/weekdays
  if [[ $_mf_type -eq 1 && ($_mf_sched_type -eq 0 || $_mf_sched_type -eq 1) ]]; then
    [[ $next -eq 5 ]] && next=7
    [[ $next -eq 6 ]] && next=7
  fi
  [[ $next -gt $max_focus ]] && next=0
  [[ $next -eq 1 && $_mf_repo_readonly -eq 1 ]] && next=2
  _mf_focus=$next
}

# Shift-Tab: previous focus, skipping read-only/locked/irrelevant fields
_modal_handle_shift_tab() {
  local max_focus
  [[ $_mf_type -eq 0 ]] && max_focus=4 || max_focus=7
  local prev=$(( _mf_focus - 1 ))
  [[ $prev -lt 0 ]] && prev=$max_focus
  # Cron mode: skip sub-fields 6,5 for daily/weekdays
  if [[ $_mf_type -eq 1 && ($_mf_sched_type -eq 0 || $_mf_sched_type -eq 1) ]]; then
    [[ $prev -eq 6 ]] && prev=4
    [[ $prev -eq 5 ]] && prev=4
  fi
  # Task mode: skip worktree if locked
  if [[ $_mf_type -eq 0 && $prev -eq 3 && $_mf_wt_locked -eq 1 ]]; then
    prev=2
  fi
  # Skip repo if readonly
  [[ $prev -eq 1 && $_mf_repo_readonly -eq 1 ]] && prev=0
  _mf_focus=$prev
}

# Select highlighted repo dropdown item
_modal_select_dropdown() {
  _mf_repo="${_mf_repo_list[$_mf_dropdown_idx]}"
  _mf_dropdown_open=0
  # Update worktree lock based on selected repo type
  if [[ "${_repo_types[$_mf_repo]:-git}" == "dir" ]]; then
    _mf_wt_locked=1
    _mf_worktree=0
  else
    _mf_wt_locked=0
  fi
  _mf_focus=2
}

# Select highlighted schedule dropdown item
_modal_select_schedule_dropdown() {
  _mf_sched_type=$_mf_sched_dd_idx
  _mf_sched_dd_open=0
  # Reset sub-fields when schedule type changes
  _mf_sched_time=""
  _mf_sched_start_h=""
  _mf_sched_end_h=""
  _mf_sched_at_min=""
  _mf_sched_interval=""
  _mf_focus=4
}

# Backspace on focused field
_modal_handle_backspace() {
  local prompt_idx
  [[ $_mf_type -eq 0 ]] && prompt_idx=4 || prompt_idx=7
  if [[ $_mf_focus -eq 2 ]]; then
    if [[ $_mf_type -eq 0 && -n "$_mf_title" ]]; then
      _mf_title="${_mf_title%?}"
    elif [[ $_mf_type -eq 1 && -n "$_mf_name" ]]; then
      _mf_name="${_mf_name%?}"
    fi
  elif [[ $_mf_focus -eq $prompt_idx && -n "$_mf_prompt" ]]; then
    _mf_prompt="${_mf_prompt%?}"
  elif [[ $_mf_type -eq 1 && $_mf_focus -ge 4 && $_mf_focus -le 6 ]]; then
    _modal_sched_backspace
  fi
}

# Backspace for schedule sub-fields
_modal_sched_backspace() {
  case $_mf_sched_type in
    0|1)
      [[ $_mf_focus -eq 4 && -n "$_mf_sched_time" ]] && _mf_sched_time="${_mf_sched_time%?}"
      ;;
    2)
      case $_mf_focus in
        4) [[ -n "$_mf_sched_start_h" ]] && _mf_sched_start_h="${_mf_sched_start_h%?}" ;;
        5) [[ -n "$_mf_sched_end_h" ]] && _mf_sched_end_h="${_mf_sched_end_h%?}" ;;
        6) [[ -n "$_mf_sched_at_min" ]] && _mf_sched_at_min="${_mf_sched_at_min%?}" ;;
      esac
      ;;
    3)
      case $_mf_focus in
        4) [[ -n "$_mf_sched_start_h" ]] && _mf_sched_start_h="${_mf_sched_start_h%?}" ;;
        5) [[ -n "$_mf_sched_end_h" ]] && _mf_sched_end_h="${_mf_sched_end_h%?}" ;;
        6) [[ -n "$_mf_sched_interval" ]] && _mf_sched_interval="${_mf_sched_interval%?}" ;;
      esac
      ;;
  esac
}

# Ctrl-U: clear focused field
_modal_handle_ctrl_u() {
  local prompt_idx
  [[ $_mf_type -eq 0 ]] && prompt_idx=4 || prompt_idx=7
  if [[ $_mf_focus -eq 2 ]]; then
    [[ $_mf_type -eq 0 ]] && _mf_title="" || _mf_name=""
  elif [[ $_mf_focus -eq $prompt_idx ]]; then
    _mf_prompt=""
  elif [[ $_mf_type -eq 1 && $_mf_focus -ge 4 && $_mf_focus -le 6 ]]; then
    _modal_sched_clear
  fi
}

# Clear schedule sub-field
_modal_sched_clear() {
  case $_mf_sched_type in
    0|1) [[ $_mf_focus -eq 4 ]] && _mf_sched_time="" ;;
    2)
      case $_mf_focus in
        4) _mf_sched_start_h="" ;; 5) _mf_sched_end_h="" ;; 6) _mf_sched_at_min="" ;;
      esac
      ;;
    3)
      case $_mf_focus in
        4) _mf_sched_start_h="" ;; 5) _mf_sched_end_h="" ;; 6) _mf_sched_interval="" ;;
      esac
      ;;
  esac
}

# Ctrl-W: delete last word in focused field
_modal_handle_ctrl_w() {
  local prompt_idx
  [[ $_mf_type -eq 0 ]] && prompt_idx=4 || prompt_idx=7
  local val=""
  if [[ $_mf_focus -eq 2 ]]; then
    [[ $_mf_type -eq 0 ]] && val="$_mf_title" || val="$_mf_name"
  elif [[ $_mf_focus -eq $prompt_idx ]]; then
    val="$_mf_prompt"
  else
    return
  fi
  while [[ "$val" == *' ' ]]; do val="${val% }"; done
  while [[ -n "$val" ]] && [[ "$val" != *' ' ]]; do val="${val%?}"; done
  if [[ $_mf_focus -eq 2 ]]; then
    [[ $_mf_type -eq 0 ]] && _mf_title="$val" || _mf_name="$val"
  else
    _mf_prompt="$val"
  fi
}

# ── Rendering ─────────────────────────────────────────────────────────────────

# Main render function: draws the modal overlay on the frozen dashboard
_modal_render() {
  local m_cols m_rows
  m_cols=$(tput cols)
  m_rows=$(tput lines)
  local m_width=$(( m_cols - 10 ))
  [[ $m_width -lt 40 ]] && m_width=40
  [[ $m_width -gt 60 ]] && m_width=60
  local m_inner=$(( m_width - 2 ))

  # Field layout constants
  local label_w=10
  local focus_w=2
  local pad_l=2
  local pad_r=2
  local field_w=$(( m_inner - pad_l - focus_w - label_w - pad_r ))

  # Repo dropdown rows
  local dd_rows=0
  if [[ $_mf_dropdown_open -eq 1 ]]; then
    dd_rows=$(( ${#_mf_repo_list[@]} + 2 ))
  fi

  # Schedule dropdown rows
  local sched_dd_rows=0
  if [[ $_mf_sched_dd_open -eq 1 ]]; then
    sched_dd_rows=6  # top border + 4 items + bottom border
  fi

  # Prompt visible lines (auto-expand)
  local content_w=$(( field_w - 2 ))
  [[ $content_w -lt 1 ]] && content_w=1
  local prompt_lines=1
  if [[ ${#_mf_prompt} -gt $content_w ]]; then
    prompt_lines=$(( (${#_mf_prompt} + content_w - 1) / content_w ))
    [[ $prompt_lines -gt 4 ]] && prompt_lines=4
  fi

  # Height: border + blank + type + repo + dd + title/name + (worktree+hint|schedule+sdd+sub) + prompt + blank + footer + border
  local m_height
  if [[ $_mf_type -eq 0 ]]; then
    m_height=$(( 1 + 1 + 1 + 1 + dd_rows + 1 + 1 + 1 + prompt_lines + 1 + 1 + 1 ))
  else
    m_height=$(( 1 + 1 + 1 + 1 + dd_rows + 1 + 1 + sched_dd_rows + 1 + prompt_lines + 1 + 1 + 1 ))
  fi
  local m_top=$(( (m_rows - m_height) / 2 ))
  [[ $m_top -lt 1 ]] && m_top=1
  local m_left=$(( (m_cols - m_width) / 2 + 1 ))

  # Clear excess rows from previous frame (prevents ghost content on height change)
  if [[ $_mf_prev_height -gt 0 ]]; then
    local prev_end=$(( _mf_prev_top + _mf_prev_height ))
    local cr
    # Rows above current modal that were in previous frame
    for (( cr=_mf_prev_top; cr < m_top && cr < prev_end; cr++ )); do
      move_to "$cr" "$m_left"
      printf "%-${m_width}s" ""
    done
    # Rows below current modal that were in previous frame
    local cur_end=$(( m_top + m_height ))
    for (( cr=cur_end; cr < prev_end; cr++ )); do
      move_to "$cr" "$m_left"
      printf "%-${m_width}s" ""
    done
  fi

  # Build horizontal bars
  local hbar="" i
  for (( i=0; i<m_inner; i++ )); do hbar+="═"; done
  local title
  [[ $_mf_type -eq 0 ]] && title=" New Task " || title=" New Cron Job "
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

  # Type toggle field
  _modal_render_field_type "$row" "$m_left" "$m_inner" "$field_w" "$label_w"
  row=$((row + 1))

  # Repo field
  _modal_render_field_repo "$row" "$m_left" "$m_inner" "$field_w" "$label_w"
  row=$((row + 1))

  # Repo dropdown (if open)
  if [[ $_mf_dropdown_open -eq 1 ]]; then
    local dd_offset=$(( pad_l + focus_w + label_w ))
    local dd_w=$field_w
    local dd_border_w=$(( dd_w - 2 ))
    local dd_border=""
    for (( i=0; i<dd_border_w; i++ )); do dd_border+="─"; done
    local dd_prefix=""
    printf -v dd_prefix "%-${dd_offset}s" ""
    local dd_suffix_w=$(( m_inner - dd_offset - dd_w ))
    [[ $dd_suffix_w -lt 0 ]] && dd_suffix_w=0
    local dd_suffix=""
    printf -v dd_suffix "%-${dd_suffix_w}s" ""

    # Top border
    move_to "$row" "$m_left"
    printf "║%s┌%s┐%s║" "$dd_prefix" "$dd_border" "$dd_suffix"
    row=$((row + 1))

    # Items
    local di
    for (( di=0; di<${#_mf_repo_list[@]}; di++ )); do
      local item="${_mf_repo_list[$di]}"
      local indicator="  "
      [[ $di -eq $_mf_dropdown_idx ]] && indicator="▸ "
      local item_text
      item_text=$(trunc "${indicator}${item}" "$dd_border_w")
      move_to "$row" "$m_left"
      printf "║%s│%-${dd_border_w}s│%s║" "$dd_prefix" "$item_text" "$dd_suffix"
      row=$((row + 1))
    done

    # Bottom border
    move_to "$row" "$m_left"
    printf "║%s└%s┘%s║" "$dd_prefix" "$dd_border" "$dd_suffix"
    row=$((row + 1))
  fi

  # Title/Name field
  if [[ $_mf_type -eq 0 ]]; then
    _modal_render_field_text "$row" "$m_left" "$m_inner" "$field_w" "$label_w" 2 "Title:" "$_mf_title"
  else
    _modal_render_field_text "$row" "$m_left" "$m_inner" "$field_w" "$label_w" 2 "Name:" "$_mf_name"
  fi
  row=$((row + 1))

  if [[ $_mf_type -eq 0 ]]; then
    # ── Task: Worktree toggle + hint ──
    _modal_render_field_toggle "$row" "$m_left" "$m_inner" "$field_w" "$label_w"
    row=$((row + 1))

    # Worktree hint line
    local hint_text=""
    if [[ $_mf_wt_locked -eq 0 ]]; then
      if [[ $_mf_worktree -eq 0 ]]; then
        hint_text="Works directly in the repo"
      else
        hint_text="Isolated branch; merges back later"
      fi
    fi
    move_to "$row" "$m_left"
    if [[ -n "$hint_text" ]]; then
      local hint_offset=$(( pad_l + focus_w + label_w ))
      local hint_max=$(( m_inner - hint_offset - 2 ))
      [[ $hint_max -lt 1 ]] && hint_max=1
      hint_text=$(trunc "$hint_text" "$hint_max")
      local plain_len=$(( hint_offset + 2 + ${#hint_text} ))
      local hint_pad=$(( m_inner - plain_len ))
      [[ $hint_pad -lt 0 ]] && hint_pad=0
      local hint_pad_str=""
      printf -v hint_pad_str "%-${hint_pad}s" ""
      printf "║%-${hint_offset}s${C_DIM}└ %s${C_RESET}%s║" "" "$hint_text" "$hint_pad_str"
    else
      printf "║%s║" "$blank_inner"
    fi
    row=$((row + 1))
  else
    # ── Cron: Schedule dropdown + sub-fields ──
    _modal_render_schedule_field "$row" "$m_left" "$m_inner" "$field_w" "$label_w"
    row=$((row + 1))

    # Schedule dropdown (if open)
    if [[ $_mf_sched_dd_open -eq 1 ]]; then
      local sd_offset=$(( pad_l + focus_w + label_w ))
      local sd_w=$field_w
      local sd_border_w=$(( sd_w - 2 ))
      local sd_border=""
      for (( i=0; i<sd_border_w; i++ )); do sd_border+="─"; done
      local sd_prefix=""
      printf -v sd_prefix "%-${sd_offset}s" ""
      local sd_suffix_w=$(( m_inner - sd_offset - sd_w ))
      [[ $sd_suffix_w -lt 0 ]] && sd_suffix_w=0
      local sd_suffix=""
      printf -v sd_suffix "%-${sd_suffix_w}s" ""

      move_to "$row" "$m_left"
      printf "║%s┌%s┐%s║" "$sd_prefix" "$sd_border" "$sd_suffix"
      row=$((row + 1))

      local sched_labels=("Daily at HH:MM" "Weekdays at HH:MM" "Hourly (range)" "Every N min (range)")
      local si
      for (( si=0; si<4; si++ )); do
        local s_indicator="  "
        [[ $si -eq $_mf_sched_dd_idx ]] && s_indicator="▸ "
        local s_item
        s_item=$(trunc "${s_indicator}${sched_labels[$si]}" "$sd_border_w")
        move_to "$row" "$m_left"
        printf "║%s│%-${sd_border_w}s│%s║" "$sd_prefix" "$s_item" "$sd_suffix"
        row=$((row + 1))
      done

      move_to "$row" "$m_left"
      printf "║%s└%s┘%s║" "$sd_prefix" "$sd_border" "$sd_suffix"
      row=$((row + 1))
    fi

    # Schedule sub-fields
    _modal_render_schedule_sub_fields "$row" "$m_left" "$m_inner" "$field_w" "$label_w"
    row=$((row + 1))
  fi

  # Prompt field (multi-line)
  local prompt_idx
  [[ $_mf_type -eq 0 ]] && prompt_idx=4 || prompt_idx=7
  local pl
  for (( pl=0; pl<prompt_lines; pl++ )); do
    local chunk_start=$(( pl * content_w ))
    local chunk="${_mf_prompt:$chunk_start:$content_w}"
    if [[ $pl -eq 0 ]]; then
      _modal_render_field_text "$row" "$m_left" "$m_inner" "$field_w" "$label_w" "$prompt_idx" "Prompt:" "$chunk"
    else
      # Continuation line: no label, aligned with field content
      local cont_offset=$(( pad_l + focus_w + label_w ))
      local cont_prefix=""
      printf -v cont_prefix "%-${cont_offset}s" ""
      local padded_chunk=""
      printf -v padded_chunk "%-${content_w}s" "$chunk"
      local right_pad=$(( m_inner - cont_offset - field_w ))
      [[ $right_pad -lt 0 ]] && right_pad=0
      local right_pad_str=""
      printf -v right_pad_str "%-${right_pad}s" ""
      move_to "$row" "$m_left"
      printf "║%s[%s]%s║" "$cont_prefix" "$padded_chunk" "$right_pad_str"
    fi
    row=$((row + 1))
  done

  # Blank line
  move_to "$row" "$m_left"
  printf "║%s║" "$blank_inner"
  row=$((row + 1))

  # Footer hints
  local footer_text=""
  if [[ $_mf_dropdown_open -eq 1 || $_mf_sched_dd_open -eq 1 ]]; then
    footer_text="  ↑/↓: select  Enter: confirm  Esc: cancel"
  else
    footer_text="  Tab: next  Shift-Tab: prev  Enter: create  Esc: cancel"
  fi
  footer_text=$(trunc "$footer_text" "$m_inner")
  move_to "$row" "$m_left"
  printf "║${C_DIM}%-${m_inner}s${C_RESET}║" "$footer_text"
  row=$((row + 1))

  # Bottom border
  move_to "$row" "$m_left"
  printf "╚%s╝" "$hbar"

  # Track frame dimensions for next render's clearing pass
  _mf_prev_top=$m_top
  _mf_prev_height=$m_height
}

# Render type toggle field
_modal_render_field_type() {
  local row=$1 m_left=$2 m_inner=$3 field_w=$4 label_w=$5
  local pad_l=2 focus_w=2
  local focus_str="  "
  [[ $_mf_focus -eq 0 ]] && focus_str="▸ "

  local task_marker="( )" cron_marker="( )"
  [[ $_mf_type -eq 0 ]] && task_marker="(•)" || cron_marker="(•)"
  local toggle_text="${task_marker} Task  ${cron_marker} Cron"

  local pad_r_w=$(( m_inner - pad_l - focus_w - label_w - field_w ))
  [[ $pad_r_w -lt 0 ]] && pad_r_w=0
  local pad_r_str=""
  printf -v pad_r_str "%-${pad_r_w}s" ""

  local val_pad=$(( field_w - ${#toggle_text} ))
  [[ $val_pad -lt 0 ]] && val_pad=0
  local val_pad_str=""
  printf -v val_pad_str "%-${val_pad}s" ""

  move_to "$row" "$m_left"
  printf "║  %s%-${label_w}s%s%s%s║" "$focus_str" "Type:" "$toggle_text" "$val_pad_str" "$pad_r_str"
}

# Render repo field row
_modal_render_field_repo() {
  local row=$1 m_left=$2 m_inner=$3 field_w=$4 label_w=$5
  local pad_l=2 focus_w=2
  local focus_str="  "
  [[ $_mf_focus -eq 1 ]] && focus_str="▸ "

  local pad_r_w=$(( m_inner - pad_l - focus_w - label_w - field_w ))
  [[ $pad_r_w -lt 0 ]] && pad_r_w=0
  local pad_r_str=""
  printf -v pad_r_str "%-${pad_r_w}s" ""

  move_to "$row" "$m_left"

  if [[ $_mf_repo_readonly -eq 1 ]]; then
    # Read-only: plain text with optional hint
    local val_pad_len=$field_w
    if [[ -n "$_mf_repo_hint" ]]; then
      local hint_extra=" ${_mf_repo_hint}"
      val_pad_len=$(( field_w - ${#_mf_repo} - ${#hint_extra} ))
      [[ $val_pad_len -lt 0 ]] && val_pad_len=0
      local val_pad_str2=""
      printf -v val_pad_str2 "%-${val_pad_len}s" ""
      printf "║  %s%-${label_w}s%s ${C_DIM}%s${C_RESET}%s%s║" \
        "$focus_str" "Repo:" "$_mf_repo" "$_mf_repo_hint" "$val_pad_str2" "$pad_r_str"
    else
      val_pad_len=$(( field_w - ${#_mf_repo} ))
      [[ $val_pad_len -lt 0 ]] && val_pad_len=0
      local val_pad_str2=""
      printf -v val_pad_str2 "%-${val_pad_len}s" ""
      printf "║  %s%-${label_w}s%s%s%s║" \
        "$focus_str" "Repo:" "$_mf_repo" "$val_pad_str2" "$pad_r_str"
    fi
  elif [[ -n "$_mf_repo" && $_mf_dropdown_open -eq 0 ]]; then
    # Selected repo, dropdown closed
    local padded=""
    printf -v padded "%-$((field_w - 2))s" "$_mf_repo"
    printf "║  %s%-${label_w}s[%s]%s║" "$focus_str" "Repo:" "$padded" "$pad_r_str"
  else
    # No repo selected or dropdown open: show placeholder with indicator
    local inner_w=$(( field_w - 4 ))
    [[ $inner_w -lt 1 ]] && inner_w=1
    local padded=""
    printf -v padded "%-${inner_w}s" "select..."
    printf "║  %s%-${label_w}s[%s] ▼%s║" "$focus_str" "Repo:" "$padded" "$pad_r_str"
  fi
}

# Render text field row (title/name or prompt first line)
_modal_render_field_text() {
  local row=$1 m_left=$2 m_inner=$3 field_w=$4 label_w=$5
  local field_idx=$6 label="$7" value="$8"
  local pad_l=2 focus_w=2
  local focus_str="  "
  [[ $_mf_focus -eq $field_idx ]] && focus_str="▸ "

  local content_w=$(( field_w - 2 ))
  [[ $content_w -lt 1 ]] && content_w=1
  local padded=""
  printf -v padded "%-${content_w}s" "$value"
  padded="${padded:0:$content_w}"

  local pad_r_w=$(( m_inner - pad_l - focus_w - label_w - field_w ))
  [[ $pad_r_w -lt 0 ]] && pad_r_w=0
  local pad_r_str=""
  printf -v pad_r_str "%-${pad_r_w}s" ""

  move_to "$row" "$m_left"
  printf "║  %s%-${label_w}s[%s]%s║" "$focus_str" "$label" "$padded" "$pad_r_str"
}

# Render worktree toggle field (task mode only)
_modal_render_field_toggle() {
  local row=$1 m_left=$2 m_inner=$3 field_w=$4 label_w=$5
  local pad_l=2 focus_w=2
  local focus_str="  "
  [[ $_mf_focus -eq 3 ]] && focus_str="▸ "

  local pad_r_w=$(( m_inner - pad_l - focus_w - label_w - field_w ))
  [[ $pad_r_w -lt 0 ]] && pad_r_w=0
  local pad_r_str=""
  printf -v pad_r_str "%-${pad_r_w}s" ""

  move_to "$row" "$m_left"
  if [[ $_mf_wt_locked -eq 1 ]]; then
    local lock_plain="(•) No  " lock_dim="(not a git repo)"
    local val_pad=$(( field_w - ${#lock_plain} - ${#lock_dim} ))
    [[ $val_pad -lt 0 ]] && val_pad=0
    local val_pad_str=""
    printf -v val_pad_str "%-${val_pad}s" ""
    printf "║  %s%-${label_w}s%s${C_DIM}%s${C_RESET}%s%s║" \
      "$focus_str" "Worktree:" "$lock_plain" "$lock_dim" "$val_pad_str" "$pad_r_str"
  else
    local no_marker="( )" yes_marker="( )"
    if [[ $_mf_worktree -eq 0 ]]; then
      no_marker="(•)"
    else
      yes_marker="(•)"
    fi
    local toggle_text="${no_marker} No  ${yes_marker} Yes"
    local val_pad=$(( field_w - ${#toggle_text} ))
    [[ $val_pad -lt 0 ]] && val_pad=0
    local val_pad_str=""
    printf -v val_pad_str "%-${val_pad}s" ""
    printf "║  %s%-${label_w}s%s%s%s║" \
      "$focus_str" "Worktree:" "$toggle_text" "$val_pad_str" "$pad_r_str"
  fi
}

# Render schedule field (cron mode, shows current selection with dropdown arrow)
_modal_render_schedule_field() {
  local row=$1 m_left=$2 m_inner=$3 field_w=$4 label_w=$5
  local pad_l=2 focus_w=2
  local focus_str="  "
  [[ $_mf_focus -eq 3 ]] && focus_str="▸ "

  local sched_labels=("Daily" "Weekdays" "Hourly" "Interval")
  local sched_text="${sched_labels[$_mf_sched_type]}"

  local pad_r_w=$(( m_inner - pad_l - focus_w - label_w - field_w ))
  [[ $pad_r_w -lt 0 ]] && pad_r_w=0
  local pad_r_str=""
  printf -v pad_r_str "%-${pad_r_w}s" ""

  local inner_w=$(( field_w - 4 ))
  [[ $inner_w -lt 1 ]] && inner_w=1
  local padded=""
  printf -v padded "%-${inner_w}s" "$sched_text"
  move_to "$row" "$m_left"
  printf "║  %s%-${label_w}s[%s] ▼%s║" "$focus_str" "Schedule:" "$padded" "$pad_r_str"
}

# Render schedule sub-fields row (cron mode, below dropdown)
_modal_render_schedule_sub_fields() {
  local row=$1 m_left=$2 m_inner=$3 field_w=$4 label_w=$5
  local pad_l=2 focus_w=2

  local sub_text=""
  case $_mf_sched_type in
    0|1)  # Daily / Weekdays
      local f4_str="  "
      [[ $_mf_focus -eq 4 ]] && f4_str="▸ "
      local time_val="${_mf_sched_time}"
      [[ -z "$time_val" ]] && time_val="${C_DIM}09:00${C_RESET}"
      sub_text="${f4_str}Time:     [${time_val}]"
      ;;
    2)  # Hourly
      local f4_str="  " f5_str="  " f6_str="  "
      [[ $_mf_focus -eq 4 ]] && f4_str="▸ "
      [[ $_mf_focus -eq 5 ]] && f5_str="▸ "
      [[ $_mf_focus -eq 6 ]] && f6_str="▸ "
      local sh="${_mf_sched_start_h}" eh="${_mf_sched_end_h}" am="${_mf_sched_at_min}"
      [[ -z "$sh" ]] && sh="${C_DIM}09${C_RESET}"
      [[ -z "$eh" ]] && eh="${C_DIM}17${C_RESET}"
      [[ -z "$am" ]] && am="${C_DIM}00${C_RESET}"
      sub_text="${f4_str}From:[${sh}] ${f5_str}To:[${eh}] ${f6_str}At:[${am}]"
      ;;
    3)  # Interval
      local f4_str="  " f5_str="  " f6_str="  "
      [[ $_mf_focus -eq 4 ]] && f4_str="▸ "
      [[ $_mf_focus -eq 5 ]] && f5_str="▸ "
      [[ $_mf_focus -eq 6 ]] && f6_str="▸ "
      local sh="${_mf_sched_start_h}" eh="${_mf_sched_end_h}" iv="${_mf_sched_interval}"
      [[ -z "$sh" ]] && sh="${C_DIM}09${C_RESET}"
      [[ -z "$eh" ]] && eh="${C_DIM}17${C_RESET}"
      [[ -z "$iv" ]] && iv="${C_DIM}30${C_RESET}"
      sub_text="${f4_str}From:[${sh}] ${f5_str}To:[${eh}] ${f6_str}Every:[${iv}]m"
      ;;
  esac

  local sub_padded
  printf -v sub_padded "%-${m_inner}s" "  $sub_text"
  # Cannot simply truncate since sub_text may contain ANSI escapes
  move_to "$row" "$m_left"
  printf "║%-${m_inner}s║" "  $sub_text"
}

# Show success flash after task creation
_modal_render_success() {
  local task_id="$1"
  local m_cols m_rows
  m_cols=$(tput cols)
  m_rows=$(tput lines)
  local m_width=$(( m_cols - 10 ))
  [[ $m_width -lt 40 ]] && m_width=40
  [[ $m_width -gt 60 ]] && m_width=60
  local m_inner=$(( m_width - 2 ))
  local m_height=6
  local m_top=$(( (m_rows - m_height) / 2 ))
  [[ $m_top -lt 1 ]] && m_top=1
  local m_left=$(( (m_cols - m_width) / 2 + 1 ))

  # Clear previous form modal's leftover rows
  if [[ $_mf_prev_height -gt 0 ]]; then
    local prev_end=$(( _mf_prev_top + _mf_prev_height ))
    local cr
    for (( cr=_mf_prev_top; cr < m_top && cr < prev_end; cr++ )); do
      move_to "$cr" "$m_left"
      printf "%-${m_width}s" ""
    done
    local cur_end=$(( m_top + m_height ))
    for (( cr=cur_end; cr < prev_end; cr++ )); do
      move_to "$cr" "$m_left"
      printf "%-${m_width}s" ""
    done
  fi

  local hbar="" i
  for (( i=0; i<m_inner; i++ )); do hbar+="═"; done
  local title=" New Task "
  local hbar_left="═══"
  local hbar_right_len=$(( m_inner - 3 - ${#title} ))
  local hbar_right=""
  for (( i=0; i<hbar_right_len; i++ )); do hbar_right+="═"; done
  local blank_inner=""
  printf -v blank_inner "%-${m_inner}s" ""

  # "✓ Created t-NNN" = 10 + len(task_id) visible chars after the 2-space indent
  local created_text="✓ Created ${task_id}"
  local created_pad=$(( m_inner - 2 - ${#created_text} ))
  [[ $created_pad -lt 0 ]] && created_pad=0
  local created_pad_str=""
  printf -v created_pad_str "%-${created_pad}s" ""

  move_to "$m_top" "$m_left"
  printf "╔%s%s%s╗" "$hbar_left" "$title" "$hbar_right"
  move_to "$((m_top + 1))" "$m_left"
  printf "║%s║" "$blank_inner"
  move_to "$((m_top + 2))" "$m_left"
  printf "║  ${C_GREEN}%s${C_RESET}%s║" "$created_text" "$created_pad_str"
  move_to "$((m_top + 3))" "$m_left"
  printf "║    %-$((m_inner - 4))s║" "Starting Claude..."
  move_to "$((m_top + 4))" "$m_left"
  printf "║%s║" "$blank_inner"
  move_to "$((m_top + 5))" "$m_left"
  printf "╚%s╝" "$hbar"
}

# Show success flash after cron job creation
_modal_render_cron_success() {
  local cron_id="$1"
  local m_cols m_rows
  m_cols=$(tput cols)
  m_rows=$(tput lines)
  local m_width=$(( m_cols - 10 ))
  [[ $m_width -lt 40 ]] && m_width=40
  [[ $m_width -gt 60 ]] && m_width=60
  local m_inner=$(( m_width - 2 ))
  local m_height=6
  local m_top=$(( (m_rows - m_height) / 2 ))
  [[ $m_top -lt 1 ]] && m_top=1
  local m_left=$(( (m_cols - m_width) / 2 + 1 ))

  if [[ $_mf_prev_height -gt 0 ]]; then
    local prev_end=$(( _mf_prev_top + _mf_prev_height ))
    local cr
    for (( cr=_mf_prev_top; cr < m_top && cr < prev_end; cr++ )); do
      move_to "$cr" "$m_left"
      printf "%-${m_width}s" ""
    done
    local cur_end=$(( m_top + m_height ))
    for (( cr=cur_end; cr < prev_end; cr++ )); do
      move_to "$cr" "$m_left"
      printf "%-${m_width}s" ""
    done
  fi

  local hbar="" i
  for (( i=0; i<m_inner; i++ )); do hbar+="═"; done
  local title=" New Cron Job "
  local hbar_left="═══"
  local hbar_right_len=$(( m_inner - 3 - ${#title} ))
  local hbar_right=""
  for (( i=0; i<hbar_right_len; i++ )); do hbar_right+="═"; done
  local blank_inner=""
  printf -v blank_inner "%-${m_inner}s" ""

  local created_text="✓ Created ${cron_id}"
  local created_pad=$(( m_inner - 2 - ${#created_text} ))
  [[ $created_pad -lt 0 ]] && created_pad=0
  local created_pad_str=""
  printf -v created_pad_str "%-${created_pad}s" ""

  move_to "$m_top" "$m_left"
  printf "╔%s%s%s╗" "$hbar_left" "$title" "$hbar_right"
  move_to "$((m_top + 1))" "$m_left"
  printf "║%s║" "$blank_inner"
  move_to "$((m_top + 2))" "$m_left"
  printf "║  ${C_GREEN}%s${C_RESET}%s║" "$created_text" "$created_pad_str"
  move_to "$((m_top + 3))" "$m_left"
  printf "║    %-$((m_inner - 4))s║" "Scheduled and loaded."
  move_to "$((m_top + 4))" "$m_left"
  printf "║%s║" "$blank_inner"
  move_to "$((m_top + 5))" "$m_left"
  printf "╚%s╝" "$hbar"
}

# ── Cron submission ──────────────────────────────────────────────────────────

# Create a cron job from modal state. Echoes the cron_id on success.
_modal_create_cron() {
  # Validate
  [[ -n "$_mf_repo" ]] || { echo "error: no repo selected" >&2; return 1; }
  [[ -n "$_mf_name" ]] || { echo "error: name is required" >&2; return 1; }
  [[ -n "$_mf_prompt" ]] || { echo "error: prompt is required" >&2; return 1; }

  # Sanitize name
  local name
  name=$(echo "$_mf_name" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | tr -cd 'a-z0-9-')
  [[ -n "$name" ]] || { echo "error: name is empty after sanitization" >&2; return 1; }

  # Derive working directory
  local working_dir
  working_dir=$(repo_path "$_mf_repo")
  [[ -n "$working_dir" ]] || { echo "error: could not determine working directory" >&2; return 1; }

  # Build schedule
  local schedule_type schedule_desc schedule_raw
  case $_mf_sched_type in
    0)  # Daily
      local time_str="${_mf_sched_time:-09:00}"
      local hour minute
      hour=$(echo "$time_str" | cut -d: -f1 | sed 's/^0*//')
      minute=$(echo "$time_str" | cut -d: -f2 | sed 's/^0*//')
      [[ -z "$hour" ]] && hour=0
      [[ -z "$minute" ]] && minute=0
      schedule_type="daily"
      schedule_desc="Daily at ${time_str}"
      schedule_raw=$(jq -n --argjson h "$hour" --argjson m "$minute" '{Hour: $h, Minute: $m}')
      ;;
    1)  # Weekdays
      local time_str="${_mf_sched_time:-09:00}"
      local hour minute
      hour=$(echo "$time_str" | cut -d: -f1 | sed 's/^0*//')
      minute=$(echo "$time_str" | cut -d: -f2 | sed 's/^0*//')
      [[ -z "$hour" ]] && hour=0
      [[ -z "$minute" ]] && minute=0
      schedule_type="weekdays"
      schedule_desc="Weekdays at ${time_str}"
      schedule_raw="["
      local sep="" wd
      for wd in 1 2 3 4 5; do
        schedule_raw="${schedule_raw}${sep}{\"Hour\":${hour},\"Minute\":${minute},\"Weekday\":${wd}}"
        sep=","
      done
      schedule_raw="${schedule_raw}]"
      ;;
    2)  # Hourly
      local start_h="${_mf_sched_start_h:-9}"
      local end_h="${_mf_sched_end_h:-17}"
      local at_min="${_mf_sched_at_min:-0}"
      start_h=$(echo "$start_h" | sed 's/^0*//')
      end_h=$(echo "$end_h" | sed 's/^0*//')
      at_min=$(echo "$at_min" | sed 's/^0*//')
      [[ -z "$start_h" ]] && start_h=0
      [[ -z "$end_h" ]] && end_h=0
      [[ -z "$at_min" ]] && at_min=0
      schedule_type="hourly"
      schedule_desc="Hourly ${start_h}:$(printf '%02d' "$at_min")-${end_h}:$(printf '%02d' "$at_min")"
      schedule_raw="["
      local sep="" h
      for (( h=start_h; h<=end_h; h++ )); do
        schedule_raw="${schedule_raw}${sep}{\"Hour\":${h},\"Minute\":${at_min}}"
        sep=","
      done
      schedule_raw="${schedule_raw}]"
      ;;
    3)  # Interval
      local start_h="${_mf_sched_start_h:-9}"
      local end_h="${_mf_sched_end_h:-17}"
      local interval="${_mf_sched_interval:-30}"
      start_h=$(echo "$start_h" | sed 's/^0*//')
      end_h=$(echo "$end_h" | sed 's/^0*//')
      interval=$(echo "$interval" | sed 's/^0*//')
      [[ -z "$start_h" ]] && start_h=0
      [[ -z "$end_h" ]] && end_h=0
      [[ -z "$interval" ]] && interval=30
      schedule_type="interval"
      schedule_desc="Every ${interval}m ${start_h}:00-${end_h}:00"
      schedule_raw="["
      local sep="" h m
      for (( h=start_h; h<=end_h; h++ )); do
        for (( m=0; m<60; m+=interval )); do
          schedule_raw="${schedule_raw}${sep}{\"Hour\":${h},\"Minute\":${m}}"
          sep=","
        done
      done
      schedule_raw="${schedule_raw}]"
      ;;
  esac

  # Build claude command (prompt-based, no model flag)
  local claude_cmd="claude -p $(printf '%q' "$_mf_prompt")"

  # Auto-capture env vars
  local env_vars
  env_vars=$(jq -n \
    --arg token "${CLAUDE_CODE_OAUTH_TOKEN:-}" \
    --arg home "$HOME" \
    --arg path "$PATH" \
    '{CLAUDE_CODE_OAUTH_TOKEN: $token, HOME: $home, PATH: $path} | with_entries(select(.value != ""))')

  # Create state record
  local cron_id
  cron_id=$(_next_cron_id)

  _lock_state || { echo "error: could not acquire lock" >&2; return 1; }
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
  launchctl load "$plist_path" 2>/dev/null || true

  echo "$cron_id"
}

