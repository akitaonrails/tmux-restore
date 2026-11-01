#!/usr/bin/env bash
# Started by tmux-restore.tmux when a tmux server starts. tmux-continuum restores then, unless it
# thinks another tmux server is running, which it decides by counting tmux processes. It can
# count this server's own short-lived forks (as the server starts its first pane), and then it
# skips the restore. So if no restore has started a few seconds in, run it here, under
# continuum's other conditions. A restore marks itself through scripts/pre-restore.sh.
sleep 3
[ "$(tmux show-option -gqv @tmux-restore-restored)" = 1 ] && exit 0
[ "$(tmux show-option -gqv @continuum-restore)" = on ] || exit 0
[ -e "$HOME/tmux_no_auto_restore" ] && exit 0 # continuum's "don't restore" file

# Another live tmux server of yours (a socket in the same directory that answers): leave it.
socket=${TMUX%%,*}
for other in "$(dirname "$socket")"/*; do
	[ -S "$other" ] && [ "$other" != "$socket" ] || continue
	tmux -S "$other" list-sessions > /dev/null 2>&1 && exit 0
done

restore=$(tmux show-option -gqv @resurrect-restore-script-path)
[ -x "$restore" ] && exec "$restore"
