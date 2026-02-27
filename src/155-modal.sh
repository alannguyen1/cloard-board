# ── New Task Creation Modal ───────────────────────────────────────────────────
# Centered overlay modal for creating tasks from the dashboard.
# All _modal_* functions access _mf_* state via zsh dynamic scoping;
# the caller (c) handler in cmd__dash_loop) declares these as local.

# Open the new-task creation modal. Returns 0 on submit, 1 on cancel.
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

  # Pre-fill logic
  if [[ "$filter_mode" != "all" && -z "${_repo_stale[$filter_mode]:-}" ]]; then
    _mf_repo="$filter_mode"
    _mf_repo_readonly=1
    _mf_focus=1
  elif [[ ${#_mf_repo_list[@]} -eq 1 ]]; then
    _mf_repo="${_mf_repo_list[0]}"
    _mf_repo_readonly=1
    _mf_repo_hint="(only repo)"
    _mf_focus=1
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

  local ch
  while true; do
    read -rk1 ch 2>/dev/null || { stty echo -raw; return 1; }
    case "$ch" in
      $'\e')
        # Check for escape sequence (arrow keys, shift-tab)
        local seq1="" seq2=""
        read -rk1 -t 0.05 seq1 2>/dev/null || true
        if [[ -z "$seq1" ]]; then
          # Plain Esc
          if [[ $_mf_dropdown_open -eq 1 ]]; then
            _mf_dropdown_open=0
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
              fi
              ;;
            B) # Down arrow
              if [[ $_mf_dropdown_open -eq 1 ]]; then
                local max_dd=$(( ${#_mf_repo_list[@]} - 1 ))
                [[ $_mf_dropdown_idx -lt $max_dd ]] && _mf_dropdown_idx=$((_mf_dropdown_idx + 1))
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
        else
          _modal_handle_tab
        fi
        ;;
      $'\n'|$'\r')
        if [[ $_mf_dropdown_open -eq 1 ]]; then
          _modal_select_dropdown
        elif [[ $_mf_focus -eq 0 && $_mf_repo_readonly -eq 0 ]]; then
          _mf_dropdown_open=1
          _mf_dropdown_idx=0
        elif [[ -n "$_mf_repo" ]]; then
          # Submit form (only if repo selected)
          stty echo -raw
          return 0
        fi
        ;;
      ' ')
        if [[ $_mf_focus -eq 2 && $_mf_wt_locked -eq 0 ]]; then
          _mf_worktree=$(( 1 - _mf_worktree ))
        elif [[ $_mf_focus -eq 1 ]]; then
          _mf_title+=" "
        elif [[ $_mf_focus -eq 3 ]]; then
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
        if [[ $_mf_focus -eq 1 ]]; then
          _mf_title+="$ch"
        elif [[ $_mf_focus -eq 3 ]]; then
          _mf_prompt+="$ch"
        fi
        ;;
    esac
    _modal_render
  done
}

# Tab: advance focus, skipping read-only/locked fields
_modal_handle_tab() {
  local next=$(( _mf_focus + 1 ))
  [[ $next -gt 3 ]] && next=0
  [[ $next -eq 0 && $_mf_repo_readonly -eq 1 ]] && next=1
  [[ $next -eq 2 && $_mf_wt_locked -eq 1 ]] && next=3
  _mf_focus=$next
}

# Shift-Tab: previous focus, skipping read-only/locked fields
_modal_handle_shift_tab() {
  local prev=$(( _mf_focus - 1 ))
  [[ $prev -lt 0 ]] && prev=3
  [[ $prev -eq 2 && $_mf_wt_locked -eq 1 ]] && prev=1
  [[ $prev -eq 0 && $_mf_repo_readonly -eq 1 ]] && prev=3
  [[ $prev -eq 2 && $_mf_wt_locked -eq 1 ]] && prev=1
  _mf_focus=$prev
}

# Select highlighted dropdown item
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
  _mf_focus=1
}

# Backspace on focused text field
_modal_handle_backspace() {
  if [[ $_mf_focus -eq 1 && -n "$_mf_title" ]]; then
    _mf_title="${_mf_title%?}"
  elif [[ $_mf_focus -eq 3 && -n "$_mf_prompt" ]]; then
    _mf_prompt="${_mf_prompt%?}"
  fi
}

# Ctrl-U: clear focused text field
_modal_handle_ctrl_u() {
  if [[ $_mf_focus -eq 1 ]]; then
    _mf_title=""
  elif [[ $_mf_focus -eq 3 ]]; then
    _mf_prompt=""
  fi
}

# Ctrl-W: delete last word in focused text field
_modal_handle_ctrl_w() {
  local val=""
  if [[ $_mf_focus -eq 1 ]]; then
    val="$_mf_title"
  elif [[ $_mf_focus -eq 3 ]]; then
    val="$_mf_prompt"
  else
    return
  fi
  while [[ "$val" == *' ' ]]; do val="${val% }"; done
  while [[ -n "$val" ]] && [[ "$val" != *' ' ]]; do val="${val%?}"; done
  if [[ $_mf_focus -eq 1 ]]; then
    _mf_title="$val"
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

  # Dropdown rows
  local dd_rows=0
  if [[ $_mf_dropdown_open -eq 1 ]]; then
    dd_rows=$(( ${#_mf_repo_list[@]} + 2 ))
  fi

  # Prompt visible lines (auto-expand)
  local content_w=$(( field_w - 2 ))
  [[ $content_w -lt 1 ]] && content_w=1
  local prompt_lines=1
  if [[ ${#_mf_prompt} -gt $content_w ]]; then
    prompt_lines=$(( (${#_mf_prompt} + content_w - 1) / content_w ))
    [[ $prompt_lines -gt 4 ]] && prompt_lines=4
  fi

  # Height: border + blank + repo + dd + title + worktree + hint + prompt + blank + footer + border
  local m_height=$(( 1 + 1 + 1 + dd_rows + 1 + 1 + 1 + prompt_lines + 1 + 1 + 1 ))
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
  local title=" New Task "
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

  # Repo field
  _modal_render_field_repo "$row" "$m_left" "$m_inner" "$field_w" "$label_w"
  row=$((row + 1))

  # Dropdown (if open)
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

  # Title field
  _modal_render_field_text "$row" "$m_left" "$m_inner" "$field_w" "$label_w" 1 "Title:" "$_mf_title"
  row=$((row + 1))

  # Worktree toggle
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

  # Prompt field (multi-line)
  local pl
  for (( pl=0; pl<prompt_lines; pl++ )); do
    local chunk_start=$(( pl * content_w ))
    local chunk="${_mf_prompt:$chunk_start:$content_w}"
    if [[ $pl -eq 0 ]]; then
      _modal_render_field_text "$row" "$m_left" "$m_inner" "$field_w" "$label_w" 3 "Prompt:" "$chunk"
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
  if [[ $_mf_dropdown_open -eq 1 ]]; then
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

# Render repo field row
_modal_render_field_repo() {
  local row=$1 m_left=$2 m_inner=$3 field_w=$4 label_w=$5
  local pad_l=2 focus_w=2
  local focus_str="  "
  [[ $_mf_focus -eq 0 ]] && focus_str="▸ "

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
      local val_pad_str=""
      printf -v val_pad_str "%-${val_pad_len}s" ""
      printf "║  %s%-${label_w}s%s ${C_DIM}%s${C_RESET}%s%s║" \
        "$focus_str" "Repo:" "$_mf_repo" "$_mf_repo_hint" "$val_pad_str" "$pad_r_str"
    else
      val_pad_len=$(( field_w - ${#_mf_repo} ))
      [[ $val_pad_len -lt 0 ]] && val_pad_len=0
      local val_pad_str=""
      printf -v val_pad_str "%-${val_pad_len}s" ""
      printf "║  %s%-${label_w}s%s%s%s║" \
        "$focus_str" "Repo:" "$_mf_repo" "$val_pad_str" "$pad_r_str"
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

# Render text field row (title or prompt first line)
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

# Render worktree toggle field
_modal_render_field_toggle() {
  local row=$1 m_left=$2 m_inner=$3 field_w=$4 label_w=$5
  local pad_l=2 focus_w=2
  local focus_str="  "
  [[ $_mf_focus -eq 2 ]] && focus_str="▸ "

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

