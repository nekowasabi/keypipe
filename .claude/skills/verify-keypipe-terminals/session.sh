#!/bin/sh
# The program verify.sh runs inside each terminal window it opens.
# Usage: session.sh <evidence-dir> <id> zsh|nvim
#
# zsh: an interactive zsh whose Return records the line buffer to <id>.recv and
#      runs nothing, so a whole-pane write can never execute as a command.
# nvim: nvim --clean in insert mode, editing <id>.recv.
dir=$1 id=$2
printf '\033]0;kpv-%s\007' "$id"
echo $$ > "$dir/$id.pid"
case $3 in
zsh)
  mkdir -p "$dir/$id.zdot"
  cat > "$dir/$id.zdot/.zshrc" <<EOF
PS1='kpv> '
kpv-accept() { print -r -- "\$BUFFER" >> '$dir/$id.recv'; BUFFER=; zle .accept-line; }
zle -N accept-line kpv-accept
[ -f '$dir/kp.env' ] && source '$dir/kp.env'
: > '$dir/$id.recv'
EOF
  ZDOTDIR="$dir/$id.zdot" exec zsh -i ;;
nvim)
  exec nvim --clean -c startinsert "$dir/$id.recv" ;;
esac
