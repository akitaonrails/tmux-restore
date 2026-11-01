#!/usr/bin/env bash
# A finished restore must release its lock: a later restore still runs, also when a restore hook
# leaves a process running in the background. Throwaway tmux server.
# usage: restore-lock-release.sh [plain|bg-hook]   RESTORE=<path to restore.sh>
set -u
mode=${1:-bg-hook}
here=$(cd "$(dirname "$0")" && pwd)
RESTORE=${RESTORE:-${PLUGINS_DIR:-$HOME/.tmux/plugins}/tmux-resurrect/scripts/restore.sh}
FIXTURE=${FIXTURE:-$here/fixtures/29-windows.txt}
D=$(mktemp -d)
trap 'tmux -L lock-release kill-server 2>/dev/null; [[ -s $D/bg.pid ]] && kill $(cat "$D/bg.pid") 2>/dev/null; rm -rf "$D" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/lock-release"{,.resurrect-restore.lock}' EXIT
T() { tmux -L lock-release "$@"; }
mkdir -p "$D/resurrect"
awk -F'\t' '$1=="state" || (($1=="pane" || $1=="window") && $3 < 2)' "$FIXTURE" > "$D/resurrect/save.txt"
ln -s save.txt "$D/resurrect/last"
post="echo done >> '$D/log'"
[[ $mode == bg-hook ]] && post+="; sleep 4242 </dev/null >/dev/null 2>&1 & echo \$! >> '$D/bg.pid'"
printf '%s\n' "set -g @resurrect-dir '$D/resurrect'" "set -g @resurrect-processes 'false'" \
	"set -g @resurrect-hook-pre-restore-all \"echo start >> '$D/log'\"" \
	"set -g @resurrect-hook-post-restore-all \"$post\"" > "$D/test.conf"
T -f "$D/test.conf" new-session -d -s scratch; sleep 1
count() { local n; n=$(grep -c "^$1\$" "$D/log" 2>/dev/null); echo "${n:-0}"; }
wait_done() { for _ in $(seq 60); do (( $(count "done") >= $1 )) && return 0; sleep 0.5; done; return 1; }
T run-shell -b "$RESTORE"; wait_done 1 || { echo "FAIL [$mode]: first restore never finished"; exit 1; }
sleep 1
T run-shell -b "$RESTORE"; wait_done 2
starts=$(count "start")
(( starts == 2 )) || { echo "FAIL [$mode]: second restore didn't run (restores started: $starts, want 2)"; exit 1; }
echo "PASS [$mode]: a later restore still runs"
