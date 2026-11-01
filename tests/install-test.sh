#!/usr/bin/env bash
# Installer test for a throwaway machine (a container or a CI VM): it installs packages and
# rewrites ~/.tmux.conf, so it refuses to run unless TMUX_RESTORE_SANDBOX=1.
#   TMUX_RESTORE_SANDBOX=1 TMUX_RESTORE_SOURCE=<repo, bundle or URL ending in /tmux-restore> \
#     tests/install-test.sh [fresh|existing|dirty]
#   fresh     no tmux config; checks a re-run changes nothing, then a save, a kill-server and the
#             restore, then --uninstall. A fake systemctl stands in for a systemd user session.
#   existing  a config with TPM and upstream tmux-resurrect: the installer swaps in the fork
#   dirty     like existing, but the resurrect checkout has local changes: it must be left alone
#   running   tmux is already running (no systemd): the plugins load into it, and the save on
#             disk isn't restored over its sessions
set -u
[[ ${TMUX_RESTORE_SANDBOX:-} == 1 ]] || { echo "refusing to run: this test rewrites ~/.tmux.conf. Set TMUX_RESTORE_SANDBOX=1 on a throwaway machine."; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
scenario=${1:-fresh}
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$1" "$2" "$3"; fi; }
ok() { if eval "$2"; then check "$1" yes yes; else check "$1" yes no; fi; }
P=$HOME/.tmux/plugins
FORK=https://github.com/andrewboldi/tmux-resurrect
as_root() { if [[ $(id -u) == 0 ]]; then "$@"; else sudo "$@"; fi; }
pkg() { # install packages the test itself needs
	if command -v apt-get > /dev/null; then as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" > /dev/null
	elif command -v dnf > /dev/null; then as_root dnf install -y -q "$@" > /dev/null
	elif command -v pacman > /dev/null; then as_root pacman -S --noconfirm --needed "$@" > /dev/null
	fi
}

tmux kill-server 2> /dev/null
rm -rf ~/.tmux ~/.tmux.conf* ~/.config/tmux ~/.config/systemd ~/.local/share/tmux ~/fake-bin
if [[ $scenario == existing || $scenario == dirty ]]; then
	command -v git > /dev/null || pkg git
	git clone -q --depth 1 https://github.com/tmux-plugins/tpm "$P/tpm"
	git clone -q --depth 1 https://github.com/tmux-plugins/tmux-resurrect "$P/tmux-resurrect"
	[[ $scenario == dirty ]] && echo "# my change" >> "$P/tmux-resurrect/resurrect.tmux"
	cat > ~/.tmux.conf <<-'EOF'
		set -g mouse on
		set -g @plugin 'tmux-plugins/tpm'
		set -g @plugin 'tmux-plugins/tmux-resurrect'
		set -g @plugin 'tmux-plugins/tmux-continuum'
		set -g @resurrect-dir '~/.local/share/tmux/resurrect'
		run '~/.tmux/plugins/tpm/tpm'
	EOF
	cp ~/.tmux.conf ~/original.conf
fi
if [[ $scenario == running ]]; then
	command -v zsh > /dev/null || pkg zsh
	touch ~/.zshrc
	mkdir -p ~/.local/share/tmux/resurrect
	cp "$here/fixtures/29-windows.txt" ~/.local/share/tmux/resurrect/save.txt
	ln -s save.txt ~/.local/share/tmux/resurrect/last
	tmux -f /dev/null new-session -d -s mine
	sleep 11 # older than continuum's 10 s "just started" window
fi
if [[ $scenario == fresh ]]; then # stand-in for a systemd user session
	mkdir -p ~/fake-bin
	printf '#!/bin/sh\necho "$*" >> "$HOME/systemctl.log"\ncase "$*" in *is-enabled*) exit 1 ;; esac\n' > ~/fake-bin/systemctl
	chmod +x ~/fake-bin/systemctl
	export PATH=$HOME/fake-bin:$PATH
	: > ~/systemctl.log
fi

bash "$here/../install.sh" > ~/install.log 2>&1
check "[$scenario] installer exits 0" 0 "$?"
grep -v '^\s*$' ~/install.log | sed 's/^/    | /'
check "[$scenario] one block in the config" 1 "$(grep -c '^# >>> tmux-restore >>>$' ~/.tmux.conf)"
check "[$scenario] continuum is the last plugin" "set -g @plugin 'tmux-plugins/tmux-continuum'" "$(grep '^set -g @plugin' ~/.tmux.conf | tail -1)"
ok "[$scenario] TPM installed" "[[ -x $P/tpm/tpm ]]"
ok "[$scenario] tmux-continuum installed" "[[ -f $P/tmux-continuum/continuum.tmux ]]"
ok "[$scenario] tmux-restore installed" "[[ -f $P/tmux-restore/tmux-restore.tmux ]]"
if [[ $scenario == dirty ]]; then
	check "[dirty] resurrect checkout left alone" "https://github.com/tmux-plugins/tmux-resurrect" "$(git -C "$P/tmux-resurrect" remote get-url origin)"
	ok "[dirty] local change kept" "grep -q '# my change' $P/tmux-resurrect/resurrect.tmux"
	ok "[dirty] says why" "grep -q 'local changes' ~/install.log"
else
	check "[$scenario] resurrect from the fork" "$FORK" "$(git -C "$P/tmux-resurrect" remote get-url origin)"
	check "[$scenario] resurrect on the fix branch" fix-concurrent-restore "$(git -C "$P/tmux-resurrect" rev-parse --abbrev-ref HEAD)"
	ok "[$scenario] resurrect has the lock" "grep -q acquire_restore_lock $P/tmux-resurrect/scripts/restore.sh"
fi
if [[ $scenario == existing || $scenario == dirty ]]; then
	ok "[$scenario] own settings kept" "grep -q '^set -g mouse on$' ~/.tmux.conf && grep -q '^set -g @resurrect-dir' ~/.tmux.conf"
	ok "[$scenario] upstream resurrect line commented out" "grep -q \"^#tmux-restore# set -g @plugin 'tmux-plugins/tmux-resurrect'\" ~/.tmux.conf"
	ok "[$scenario] own continuum line moved into the block" "grep -q \"^#tmux-restore# set -g @plugin 'tmux-plugins/tmux-continuum'\" ~/.tmux.conf"
	check "[$scenario] original config kept" "$(cat ~/original.conf)" "$(cat ~/.tmux.conf.before-tmux-restore 2> /dev/null)"
	check "[$scenario] TPM's run line still last" "run '~/.tmux/plugins/tpm/tpm'" "$(tail -1 ~/.tmux.conf)"
fi

cp ~/.tmux.conf ~/after-first.conf
bash "$here/../install.sh" > ~/install2.log 2>&1
check "[$scenario] re-run exits 0" 0 "$?"
check "[$scenario] re-run leaves the config alone" "$(cat ~/after-first.conf)" "$(cat ~/.tmux.conf)"

if [[ $scenario == fresh ]]; then
	ok "[fresh] unit written with the plugin's path" "grep -q '^ExecStart=\"$P/tmux-restore/scripts/shutdown-save.sh\"$' ~/.config/systemd/user/tmux-restore.service"
	ok "[fresh] unit enabled and started" "grep -q '^--user enable -q tmux-restore.service$' ~/systemctl.log && grep -q '^--user restart tmux-restore.service$' ~/systemctl.log"
	ok "[fresh] gdbus installed (shutdown save)" "command -v gdbus > /dev/null"

	# A real save, kill-server and automatic restore. In zsh, a command that isn't safe to re-run
	# must come back typed on the prompt, which proves resurrect ran the hook's TMUX_RESTORE=1 line.
	command -v zsh > /dev/null || pkg zsh
	touch ~/.zshrc
	echo "set -g default-shell $(command -v zsh)" >> ~/.tmux.conf
	tmux new-session -d -s main -n first
	sleep 3
	check "[fresh] hook registered" "$P/tmux-restore/scripts/save-hook.sh" "$(tmux show -gqv @resurrect-hook-post-save-layout)"
	ok "[fresh] restore marker registered" "tmux show -gqv @resurrect-processes | grep -qF '\"~^TMUX_RESTORE=1 \"'"
	check "[fresh] continuum restores on start" on "$(tmux show -gqv @continuum-restore)"
	tmux new-window -d -t main -n work
	sleep 1
	tmux send-keys -t main:work 'sleep 4242' Enter
	sleep 1
	tmux run-shell "$(tmux show -gqv @resurrect-save-script-path) quiet"
	save=$(readlink -f ~/.local/share/tmux/resurrect/last)
	ok "[fresh] save rewritten by the hook" "grep -qF \"TMUX_RESTORE=1 print -rz -- 'sleep 4242'\" '$save'"
	tmux kill-server
	sleep 1
	tmux new-session -d -s scratch
	# Hands off while continuum decides whether to restore: it counts running tmux commands, and
	# skips the restore if it sees more than the one that started the server.
	sleep 5
	for _ in $(seq 30); do tmux has-session -t main 2> /dev/null && tmux list-windows -t main -F '#W' | grep -qx work && break; sleep 1; done
	sleep 3
	ok "[fresh] restored on start" "tmux list-windows -t main -F '#W' | grep -qx work"
	screen=$(tmux capture-pane -p -t main:work)
	ok "[fresh] resurrect ran the hook's command" "grep -qF \"TMUX_RESTORE=1 print -rz -- 'sleep 4242'\" <<< \"\$screen\""
	check "[fresh] command typed on the prompt" "sleep 4242" "$(grep -v '^[[:space:]]*$' <<< "$screen" | tail -1 | grep -o 'sleep 4242$')"
	check "[fresh] ...and not run" zsh "$(tmux display -p -t main:work '#{pane_current_command}')"
	tmux kill-server

	bash "$here/../install.sh" --uninstall > ~/uninstall.log 2>&1
	check "[fresh] uninstall exits 0" 0 "$?"
	ok "[fresh] block removed" "! grep -q 'tmux-restore' ~/.tmux.conf"
	ok "[fresh] unit removed" "[[ ! -e ~/.config/systemd/user/tmux-restore.service ]]"
	ok "[fresh] plugin removed" "[[ ! -d $P/tmux-restore ]]"
fi
if [[ $scenario == running ]]; then
	check "[running] hook loaded into the running server" "$P/tmux-restore/scripts/save-hook.sh" "$(tmux show -gqv @resurrect-hook-post-save-layout)"
	ok "[running] restore marker loaded" "tmux show -gqv @resurrect-processes | grep -qF '\"~^TMUX_RESTORE=1 \"'"
	ok "[running] says it loaded" "grep -q 'Loaded into your running tmux server' ~/install.log"
	ok "[running] no save-at-shutdown without systemd, and says so" "grep -q 'No systemd user session' ~/install.log && [[ ! -e ~/.config/systemd/user/tmux-restore.service ]]"
	sleep 6
	check "[running] its sessions left alone (nothing restored)" mine "$(tmux list-sessions -F '#S' | tr '\n' ' ' | sed 's/ $//')"
	tmux set -g default-shell "$(command -v zsh)"
	tmux new-window -d -t mine -n work "$(command -v zsh)"
	sleep 1
	tmux send-keys -t mine:work 'sleep 4242' Enter
	sleep 1
	tmux run-shell "$(tmux show -gqv @resurrect-save-script-path) quiet"
	ok "[running] saves get rewritten" "grep -qF \"TMUX_RESTORE=1 print -rz -- 'sleep 4242'\" \"\$(readlink -f ~/.local/share/tmux/resurrect/last)\""
	bash "$here/../install.sh" --uninstall > ~/uninstall.log 2>&1
	check "[running] uninstall gives back the save hook" "" "$(tmux show -gqv @resurrect-hook-post-save-layout)"
	check "[running] ...and the restore hook" "" "$(tmux show -gqv @resurrect-hook-pre-restore-all)"
	tmux kill-server
fi
if [[ $scenario == existing ]]; then
	bash "$here/../install.sh" --uninstall > ~/uninstall.log 2>&1
	check "[existing] uninstall puts the config back" "$(cat ~/original.conf)" "$(cat ~/.tmux.conf)"
fi
echo "passed=$pass failed=$fail"; (( fail == 0 ))
