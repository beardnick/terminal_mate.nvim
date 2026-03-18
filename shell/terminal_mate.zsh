if [[ -n "${TERMINAL_MATE_ZSH_INTEGRATION_LOADED:-}" ]]; then
  return 0
fi

typeset -gx TERMINAL_MATE_ZSH_INTEGRATION_LOADED=1

autoload -Uz add-zsh-hook add-zle-hook-widget

_tmate_emit_osc() {
  printf '\e]%s\e\\' "$1"
}

_tmate_emit_osc7() {
  local host="${HOST:-localhost}"
  _tmate_emit_osc "7;file://${host}${PWD}"
}

_tmate_emit_osc133() {
  _tmate_emit_osc "133;$1"
}

_tmate_precmd() {
  local exit_status=$?

  if [[ -n "${_TMATE_COMMAND_ACTIVE:-}" ]]; then
    _tmate_emit_osc133 "D;${exit_status}"
    unset _TMATE_COMMAND_ACTIVE
  fi

  _tmate_emit_osc7
  _tmate_emit_osc133 "A"
}

_tmate_preexec() {
  typeset -gx _TMATE_COMMAND_ACTIVE=1
  _tmate_emit_osc133 "C"
}

_tmate_chpwd() {
  _tmate_emit_osc7
}

_tmate_line_init() {
  _tmate_emit_osc133 "B"
}

_tmate_zshexit() {
  local exit_status=$?
  if [[ -n "${_TMATE_COMMAND_ACTIVE:-}" ]]; then
    _tmate_emit_osc133 "D;${exit_status}"
  fi
}

add-zsh-hook chpwd _tmate_chpwd
add-zsh-hook precmd _tmate_precmd
add-zsh-hook preexec _tmate_preexec
add-zsh-hook zshexit _tmate_zshexit
add-zle-hook-widget line-init _tmate_line_init

_tmate_emit_osc7
