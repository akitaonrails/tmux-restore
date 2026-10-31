#!/usr/bin/env bash
# Run by tmux-shutdown-save.service. Holds a logind "delay" inhibitor lock; on shutdown/reboot
# logind announces PrepareForShutdown and waits for the lock to be released (up to
# InhibitDelayMaxSec, 5s by default), and we use that window to save tmux.
if [[ ${1:-} != --locked ]]; then
	exec systemd-inhibit --what=shutdown --mode=delay --who=tmux-resurrect \
		--why="Saving tmux sessions" "$0" --locked
fi

while read -r line; do
	[[ $line == *".PrepareForShutdown (true,)"* ]] || continue
	if tmux has-session 2>/dev/null; then
		save=$(tmux show -gqv @resurrect-save-script-path)  # set by tmux-resurrect
		"${save:-$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh}" quiet &&
			echo "tmux sessions saved before shutdown"
	fi
	exit 0  # releases the lock (systemd-inhibit exits with us)
done < <(gdbus monitor --system --dest org.freedesktop.login1 --object-path /org/freedesktop/login1)
exit 1  # monitor ended without a shutdown signal: fail so systemd restarts us
