#!/usr/bin/env bash
# Regression test: a login that runs a short-lived `tmux start-server` first (tmuxinator does)
# must trigger exactly ONE restore, and every layout must come back exact. Throwaway server
# with TPM, tmux-resurrect, tmux-continuum and this plugin; continuum's "another server is
# running" check is disabled in a plugin copy so auto-restore behaves as at boot even though
# your own tmux server exists.
# PLUGINS_DIR (default ~/.tmux/plugins) must contain tpm, tmux-resurrect and tmux-continuum.
set -u
here=$(cd "$(dirname "$0")" && pwd)
PLUGINS_DIR=${PLUGINS_DIR:-$HOME/.tmux/plugins}
D=$(mktemp -d); trap 'command tmux -L login-replay kill-server 2>/dev/null; rm -rf "$D" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/login-replay"{,.resurrect-restore.lock}' EXIT
mkdir -p "$D/resurrect"; cp "$here/fixtures/29-windows.txt" "$D/resurrect/save.txt"; ln -s save.txt "$D/resurrect/last"
for p in tpm tmux-resurrect tmux-continuum; do
	[[ -d $PLUGINS_DIR/$p ]] || { echo "FAIL: $PLUGINS_DIR/$p not found (set PLUGINS_DIR)"; exit 1; }
done
# -L: copy real files, so the edit below can't reach the originals through a symlink (dangling
# test-only links in a resurrect checkout without its submodule are skipped)
mkdir "$D/plugins"; cp -rL "$PLUGINS_DIR"/{tpm,tmux-resurrect,tmux-continuum} "$D/plugins/" 2>/dev/null
cp -r "$here/.." "$D/plugins/tmux-restore"
printf '\nanother_tmux_server_running_on_startup() { return 1; }\nanother_tmux_server_running() { return 1; }\n' >> "$D/plugins/tmux-continuum/scripts/helpers.sh"
cat > "$D/test.conf" <<EOC
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @plugin 'andrewboldi/tmux-restore'
# TPM reads @plugin lines from ~/.tmux.conf, not from this file, but it does read @tpm_plugins
set -g @tpm_plugins 'tmux-plugins/tpm tmux-plugins/tmux-resurrect andrewboldi/tmux-restore tmux-plugins/tmux-continuum'
set -g @continuum-restore 'on'
set -g @resurrect-dir '$D/resurrect'
set -g @resurrect-processes 'false'
set -g default-size 254x75
set -g @resurrect-hook-pre-restore-all 'echo restore-start >> $D/restores.log'
set-environment -g TMUX_PLUGIN_MANAGER_PATH '$D/plugins/'
run '$D/plugins/tpm/tpm'
EOC
(
	unset TMUX TMUX_PANE
	export HOME=$D/home XDG_CONFIG_HOME=$D/home/.config # so TPM doesn't also read your ~/.tmux.conf
	mkdir -p "$HOME"
	tmux() { command tmux -L login-replay -f "$D/test.conf" "$@"; }
	tmux start-server
	cd ~ && tmux new-session -d -s main -n term
	tmux new-window -c ~ -k -t main:0 -n term
	tmux send-keys -t main:0 clear C-m
	tmux select-window -t main:0
	tmux select-pane -t main:0.0
)
sleep 25
restores=$(wc -l < "$D/restores.log" 2>/dev/null || echo 0)
norm() { sed -E 's/^[0-9a-f]{4},//; s/([0-9]+x[0-9]+,[0-9]+,[0-9]+),[0-9]+/\1/g'; }
bad=0
while IFS=$'\t' read -r w saved; do
	exp=$(printf '%s' "$saved" | norm); got=$(command tmux -L login-replay display -p -t "main:$w" '#{window_layout}' 2>/dev/null | norm)
	[[ $got == "$exp" ]] || { bad=$((bad + 1)); echo "  window $w: saved [$exp] restored [$got]"; }
done < <(awk -F'\t' '$1=="window"{print $3 "\t" $7}' "$D/resurrect/save.txt")
(( restores == 1 && bad == 0 )) || { echo "FAIL: restores started=$restores (want 1), windows wrong=$bad"; exit 1; }
echo "PASS: one restore, all windows exact"
