#!/usr/bin/env bash
# scripts/lib.sh's process helpers against real processes: /proc on Linux, ps and lsof elsewhere
# (macOS). A copy of sleep named "codex", holding a rollout file open, also goes through the
# Codex adapter the way the save hook sees an agent.
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/lib.sh
source "$here/../scripts/lib.sh"
# shellcheck source=agents/codex.sh
source "$here/../agents/codex.sh"
D=$(mktemp -d)
D=$(cd "$D" && pwd -P) # macOS: /var is a symlink, and lsof reports real paths
pids=()
trap 'kill "${pids[@]}" 2> /dev/null; rm -rf "$D"' EXIT
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$1" "$2" "$3"; fi; }
yes_no() { if "$@"; then echo yes; else echo no; fi; }

mkdir -p "$D/work dir" "$D/bin" "$D/sessions/2026/10/31"
# The fake agent: a copy of sleep named codex. A multi-call coreutils (uutils) won't run under
# another name, so there it's a script named codex, as when an agent starts from a shell wrapper.
cp "$(command -v sleep)" "$D/bin/codex"
argv="$D/bin/codex"
if ! "$D/bin/codex" 0 2> /dev/null; then
	printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$D/bin/codex"
	chmod +x "$D/bin/codex"
	argv="/bin/sh $D/bin/codex"
fi
fake_codex() { cd "$D/work dir" && exec "$D/bin/codex" "$@"; } # run with &: becomes the agent
u=11111111-2222-3333-4444-555555555555
rollout="$D/sessions/2026/10/31/rollout-2026-10-31T10-00-00-$u.jsonl"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","source":"cli","thread_source":"user"}}\n' "$u" "$D/work dir" > "$rollout"
start=$(date +%s)
fake_codex 300 3< "$rollout" &
agent=$!
pids+=("$agent")
sleep 1

check "proc_comm" codex "$(proc_comm "$agent")"
proc_argv "$agent"
check "proc_argv" "$argv 300" "${ARGV[*]}"
check "proc_name" codex "$(proc_name "$agent")"
proc_args "$agent"
check "proc_args" 300 "${ARGV[*]}"
check "proc_cwd (with a space)" "$D/work dir" "$(proc_cwd "$agent")"
check "proc_ppid" "$$" "$(proc_ppid "$agent")"
check "proc_children" yes "$(yes_no grep -qx "$agent" <(proc_children $$))"
check "procs_named" yes "$(yes_no grep -qx "$agent" <(procs_named codex))"
check "proc_open_files" yes "$(yes_no grep -qxF "$rollout" <(proc_open_files "$agent"))"
started=$(proc_start_epoch "$agent")
check "proc_start_epoch" yes "$( ((started >= start - 2 && started <= $(date +%s) + 1)) && echo yes || echo "no ($started, started at $start)")"
if [[ -n $HAVE_PROCFS ]]; then
	check "proc_env" "$HOME" "$(proc_env "$agent" HOME)"
	[[ $argv == "$D/bin/codex" ]] && check "proc_exe" "$D/bin/codex" "$(proc_exe "$agent")"
fi

check "codex_match" yes "$(yes_no codex_match "$agent")"
check "codex_session" "$rollout" "$(codex_session "$agent")"
check "codex_resume" "codex resume $u -C $(printf '%q' "$D/work dir")" "$(codex_resume "$agent" "$rollout")"
check "alone_in_cwd: alone" yes "$(yes_no alone_in_cwd "$agent")"
fake_codex 301 &
pids+=($!)
sleep 1
check "alone_in_cwd: another codex here" no "$(yes_no alone_in_cwd "$agent")"

echo "passed=$pass failed=$fail ($(uname -s))"
((fail == 0))
