#!/usr/bin/env bash
# tmux-continuum skips its restore when it counts more than one other tmux process, which can
# happen by accident at startup. tmux-restore's safety net must then restore, exactly once and
# with every layout exact, but not when continuum's halt file exists or another tmux server is
# running. A decoy process named "tmux-decoy" makes continuum skip every time. Throwaway servers
# in their own socket directory and HOME.
# PLUGINS_DIR (default ~/.tmux/plugins) must contain tpm, tmux-resurrect and tmux-continuum.
set -u
here=$(cd "$(dirname "$0")" && pwd)
PLUGINS_DIR=${PLUGINS_DIR:-$HOME/.tmux/plugins}
D=$(mktemp -d)
decoy=""
cleanup() {
	TMUX_TMPDIR=$D/sock command tmux -L safety kill-server 2> /dev/null
	TMUX_TMPDIR=$D/sock command tmux -L other kill-server 2> /dev/null
	[[ -n $decoy ]] && kill "$decoy" 2> /dev/null
	rm -rf "$D"
}
trap cleanup EXIT
for p in tpm tmux-resurrect tmux-continuum; do
	[[ -d $PLUGINS_DIR/$p ]] || { echo "FAIL: $PLUGINS_DIR/$p not found (set PLUGINS_DIR)"; exit 1; }
done
mkdir -p "$D/plugins" "$D/sock" "$D/home"
cp -rL "$PLUGINS_DIR"/{tpm,tmux-resurrect,tmux-continuum} "$D/plugins/" 2> /dev/null
cp -r "$here/.." "$D/plugins/tmux-restore"
cat > "$D/test.conf" <<EOC
set -g @tpm_plugins 'tmux-plugins/tpm tmux-plugins/tmux-resurrect andrewboldi/tmux-restore tmux-plugins/tmux-continuum'
set -g @continuum-restore 'on'
set -g @resurrect-dir '$D/resurrect'
set -g @resurrect-processes 'false'
set -g default-size 254x75
set -g @resurrect-hook-pre-restore-all 'echo restore-start >> $D/restores.log'
set-environment -g TMUX_PLUGIN_MANAGER_PATH '$D/plugins/'
run '$D/plugins/tpm/tpm'
EOC
bash -c 'exec -a tmux-decoy sleep 300' &
decoy=$!

# start [halt|other]: a fresh server on the saved session; prints how many restores started
start() {
	(
		export HOME=$D/home XDG_CONFIG_HOME=$D/home/.config TMUX_TMPDIR=$D/sock
		unset TMUX TMUX_PANE
		rm -rf "$D/resurrect" "$D/restores.log" "$HOME/tmux_no_auto_restore"
		mkdir -p "$D/resurrect"
		cp "$here/fixtures/29-windows.txt" "$D/resurrect/save.txt"
		ln -s save.txt "$D/resurrect/last"
		[[ ${1:-} == halt ]] && touch "$HOME/tmux_no_auto_restore"
		[[ ${1:-} == other ]] && command tmux -L other -f /dev/null new-session -d
		command tmux -L safety kill-server 2> /dev/null
		while command tmux -L safety list-sessions > /dev/null 2>&1; do sleep 0.2; done
		command tmux -L safety -f "$D/test.conf" new-session -d -s main
		sleep 12
		command tmux -L safety has-session -t main 2> /dev/null || echo "FAIL: the test server isn't running" >&2
		command tmux -L other kill-server 2> /dev/null
	)
	{ wc -l < "$D/restores.log"; } 2> /dev/null || echo 0
}

fail=0
restores=$(start)
norm() { # a layout's geometry, "WxH,X,Y ..." in tree order, from the old format or tmux 3.8's JSON
	grep -oE '[0-9]+x[0-9]+,[0-9]+,[0-9]+|"w":[0-9]+,"h":[0-9]+,"x":[0-9]+,"y":[0-9]+' |
		sed -E 's/"w":([0-9]+),"h":([0-9]+),"x":([0-9]+),"y":([0-9]+)/\1x\2,\3,\4/' | tr '\n' ' '
}
bad=0
while IFS=$'\t' read -r w saved; do
	exp=$(printf '%s' "$saved" | norm)
	got=$(TMUX_TMPDIR=$D/sock command tmux -L safety display -p -t "main:$w" '#{window_layout}' 2> /dev/null | norm)
	[[ $got == "$exp" ]] || bad=$((bad + 1))
done < <(awk -F'\t' '$1=="window"{print $3 "\t" $7}' "$here/fixtures/29-windows.txt")
if ((restores == 1 && bad == 0)); then echo "ok   continuum skipped: one restore, all windows exact"; else echo "FAIL continuum skipped: restores=$restores (want 1), windows wrong=$bad"; fail=1; fi
restores=$(start halt)
if ((restores == 0)); then echo "ok   halt file: no restore"; else echo "FAIL halt file: restores=$restores (want 0)"; fail=1; fi
restores=$(start other)
if ((restores == 0)); then echo "ok   another server running: no restore"; else echo "FAIL another server running: restores=$restores (want 0)"; fail=1; fi
((fail == 0)) && echo "PASS: safety net" || exit 1
