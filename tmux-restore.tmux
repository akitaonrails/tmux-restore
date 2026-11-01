#!/usr/bin/env bash
# tmux-restore: sets up tmux-resurrect and tmux-continuum so that tmux comes back after a reboot,
# with each coding agent's conversation. Options you set yourself are left alone.
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

option() { tmux show-option -gqv "$1"; }
default() { [ -n "$(option "$1")" ] || tmux set-option -g "$1" "$2"; }

main() {
	default @continuum-restore on        # restore when the tmux server starts
	default @continuum-save-interval 1   # save every minute
	default @resurrect-capture-pane-contents on
	[ "$(uname -s)" = Linux ] && default @resurrect-save-command-strategy linux_procfs

	# The save hook rewrites each pane's command (scripts/save-hook.sh). A hook you already had
	# runs after it.
	local hook="$CURRENT_DIR/scripts/save-hook.sh" current
	current=$(option @resurrect-hook-post-save-layout)
	[ -n "$current" ] && [ "$current" != "$hook" ] && tmux set-option -g @tmux-restore-next-hook "$current"
	tmux set-option -g @resurrect-hook-post-save-layout "$hook"

	# Mark each restore, and restore here if tmux-continuum skips it by mistake
	# (scripts/restore-safety-net.sh). Only on a server that just started, like continuum.
	hook="$CURRENT_DIR/scripts/pre-restore.sh"
	current=$(option @resurrect-hook-pre-restore-all)
	[ -n "$current" ] && [ "$current" != "$hook" ] && tmux set-option -g @tmux-restore-next-pre-restore-hook "$current"
	tmux set-option -g @resurrect-hook-pre-restore-all "$hook"
	local started
	started=$(tmux display-message -p '#{start_time}')
	[ -n "$started" ] && [ $(($(date +%s) - started)) -le 10 ] && tmux run-shell -b "$CURRENT_DIR/scripts/restore-safety-net.sh"

	# Commands the hook writes start with TMUX_RESTORE=1: have resurrect run them on restore,
	# unless you turned off restoring programs ('false') or restore all of them (':all:').
	local procs marker='"~^TMUX_RESTORE=1 "'
	procs=$(option @resurrect-processes)
	case $procs in
	false | :all: | *"$marker"*) ;;
	*) tmux set-option -g @resurrect-processes "${procs:+$procs }$marker" ;;
	esac
}
main
