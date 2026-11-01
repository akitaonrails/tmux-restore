#!/usr/bin/env bash
# tmux-resurrect pre-restore-all hook: marks that a restore has started (see
# scripts/restore-safety-net.sh), then runs the hook you had before tmux-restore, if any.
tmux set-option -g @tmux-restore-restored 1
next=$(tmux show-option -gqv @tmux-restore-next-pre-restore-hook)
[ -n "$next" ] && eval "$next"
exit 0
