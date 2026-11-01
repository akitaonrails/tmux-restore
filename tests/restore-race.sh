#!/usr/bin/env bash
# Regression test: restoring a saved 29-window session must reproduce every window's layout
# exactly, even when two restores run at once (they used to race and leave extra panes squashed
# to 1 line). Throwaway tmux server, no programs relaunched.
# usage: restore-race.sh [double|single]
#   RESTORE=<path to restore.sh>  default: tmux-resurrect under PLUGINS_DIR (~/.tmux/plugins)
set -u
mode=${1:-double}
here=$(cd "$(dirname "$0")" && pwd)
RESTORE=${RESTORE:-${PLUGINS_DIR:-$HOME/.tmux/plugins}/tmux-resurrect/scripts/restore.sh}
D=$(mktemp -d); trap 'tmux -L restore-race kill-server 2>/dev/null; rm -rf "$D" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/restore-race"{,.resurrect-restore.lock}' EXIT
T() { tmux -L restore-race "$@"; }
mkdir -p "$D/resurrect"; cp "$here/fixtures/29-windows.txt" "$D/resurrect/save.txt"; ln -s save.txt "$D/resurrect/last"
printf '%s\n' "set -g @resurrect-dir '$D/resurrect'" "set -g @resurrect-processes 'false'" "set -g default-size 254x75" > "$D/test.conf"
T -f "$D/test.conf" new-session -d -s main -n term; sleep 2
if [[ $mode == single ]]; then T run-shell "$RESTORE"; else T run-shell -b "$RESTORE"; T run-shell -b "$RESTORE"; fi
want=$(grep -c $'^window\t' "$D/resurrect/save.txt")
for _ in $(seq 60); do sleep 1; (( $(T list-windows -t main 2>/dev/null | wc -l) >= want )) && break; done; sleep 5
norm() { # a layout's geometry, "WxH,X,Y ..." in tree order, from the old format or tmux 3.8's JSON
	grep -oE '[0-9]+x[0-9]+,[0-9]+,[0-9]+|"w":[0-9]+,"h":[0-9]+,"x":[0-9]+,"y":[0-9]+' |
		sed -E 's/"w":([0-9]+),"h":([0-9]+),"x":([0-9]+),"y":([0-9]+)/\1x\2,\3,\4/' | tr '\n' ' '
}
bad=0
while IFS=$'\t' read -r w saved; do
	exp=$(printf '%s' "$saved" | norm); got=$(T display -p -t "main:$w" '#{window_layout}' 2>/dev/null | norm)
	[[ $got == "$exp" ]] || { bad=$((bad + 1)); echo "  window $w: saved [$exp] restored [$got]"; }
done < <(awk -F'\t' '$1=="window"{print $3 "\t" $7}' "$D/resurrect/save.txt")
(( bad )) && { echo "FAIL [$mode]: $bad/$want windows wrong"; exit 1; }
echo "PASS [$mode]: all $want windows restored exactly"
