#!/usr/bin/env bash
# Saves tmux now, if a tmux server is running. The macOS shutdown watcher runs this; its output
# goes to ~/Library/Logs/tmux-restore.log.
if ! tmux has-session 2> /dev/null; then
	echo "$(date '+%F %T') no tmux server to save"
	exit 0
fi
save=$(tmux show-option -gqv @resurrect-save-script-path) # set by tmux-resurrect
if "${save:-$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh}" quiet; then
	echo "$(date '+%F %T') tmux saved"
else
	echo "$(date '+%F %T') tmux save failed ($?)"
fi
