# keypipe ZLE widget: runs the JSON rules on the line being typed at a zsh prompt.
# Source from .zshrc after setting KEYPIPE_BIN and KEYPIPE_CONFIG (KEYPIPE_APP optional).
# The daemon stays silent in terminals; this widget and `keypipe --line` act instead.

[[ -x $KEYPIPE_BIN && -r $KEYPIPE_CONFIG ]] || return 0
typeset -ga _keypipe_triggers
_keypipe_triggers=(${(f)"$("$KEYPIPE_BIN" --config "$KEYPIPE_CONFIG" --triggers 2>/dev/null)"})
(( ${#_keypipe_triggers} )) || return 0

_keypipe_self_insert() {
  zle .self-insert
  local t line out rc
  local -a app
  [[ -n $KEYPIPE_APP ]] && app=(--app "$KEYPIPE_APP")
  for t in $_keypipe_triggers; do
    [[ $LBUFFER == *"$t" ]] || continue
    line="${LBUFFER%"$t"}$RBUFFER"
    # Why: $(...) strips trailing newlines, so a sentinel and the exit code ride after the line.
    out=$(print -rn -- "$line" | "$KEYPIPE_BIN" --config "$KEYPIPE_CONFIG" --line "$t" $app 2>/dev/null; print -rn -- "KP_END$?")
    rc=${out##*KP_END}
    out=${out%KP_END*}
    # Any other exit leaves the buffer as typed, trigger included.
    if [[ $rc == 0 ]]; then
      BUFFER=$out
      CURSOR=${#BUFFER}
    fi
    return
  done
}
zle -N self-insert _keypipe_self_insert
