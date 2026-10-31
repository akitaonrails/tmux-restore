#!/usr/bin/env bash
# tmux-resurrect post-save-layout hook (@resurrect-hook-post-save-layout). Rewrites the command
# saved for each pane so that a restore does the right thing:
#   claude        -> "claude --resume <session-id> <original flags>": reopens the same conversation
#                    (id from Claude Code's ~/.claude/sessions/<pid>.json; initial prompt dropped).
#                    A session with no transcript yet (nothing typed) gets --session-id <id> instead.
#   safe programs -> unchanged; resurrect re-runs them (its defaults + @resurrect-processes)
#   anything else -> "print -rz -- '<cmd>'": zsh puts it on the prompt, you press Enter to run it.
#                    With another default-shell it is left unchanged, so it isn't re-run.
set -u

# claude flags that take a value (claude --help, v2.1.316): required <x>, variadic <x...> (all
# following non-flag words), optional [x] (next word if it isn't a flag). Needed so a flag's value
# isn't mistaken for the initial prompt.
value_flags=" --agent --agents --append-system-prompt --autocompact --debug-file --effort --environment --fallback-model --input-format --json-schema --max-budget-usd --model -n --name --output-format --permission-mode --permission-prompts --plugin-dir --plugin-url --remote-control-session-name-prefix --session-id --setting-sources --settings --system-prompt --system-prompt-snapshot "
variadic_flags=" --add-dir --allowedTools --allowed-tools --betas --disallowedTools --disallowed-tools --file --mcp-config --tools "
optional_flags=" --cloud -d --debug --from-pr --prompt-suggestions --remote-control -r --resume --teleport -w --worktree "
# flags that pick or start a conversation; replaced by --resume <id>
drop_flags=" -c --continue -r --resume --session-id --fork-session --from-pr --teleport "

# Shell-quoted claude args worth keeping on resume: every flag (with its values) except
# drop_flags. Positional words are the initial prompt and are dropped.
claude_keep_args() {
	local -a args=("$@") out=() group=()
	local i=0 arg flag
	while (( i < ${#args[@]} )); do
		arg=${args[i++]}
		[[ $arg == -- ]] && break
		[[ $arg == -* ]] || continue
		flag=${arg%%=*}
		group=("$arg")
		if [[ $arg != *=* ]]; then
			if [[ $value_flags == *" $flag "* ]]; then
				(( i < ${#args[@]} )) && group+=("${args[i++]}")
			elif [[ $variadic_flags == *" $flag "* ]]; then
				while (( i < ${#args[@]} )) && [[ ${args[i]} != -* ]]; do group+=("${args[i++]}"); done
			elif [[ $optional_flags == *" $flag "* ]] && (( i < ${#args[@]} )) && [[ ${args[i]} != -* ]]; then
				group+=("${args[i++]}")
			fi
		fi
		[[ $drop_flags == *" $flag "* ]] || out+=("${group[@]}")
	done
	(( ${#out[@]} )) && printf ' %q' "${out[@]}"
	return 0
}

# Start time of process $1 (field 22 of /proc/<pid>/stat), which Claude records as procStart.
proc_start() {
	local stat
	stat=$(<"/proc/$1/stat") || return 1
	stat=${stat##*) }  # drop "pid (comm) "; comm may contain spaces
	set -- $stat
	echo "${20}"
}

# "systemd-run ... MemoryMax=N " when claude runs in a memory-capped systemd scope
# (e.g. started via `systemd-run --user --scope -p MemoryMax=8G claude`).
scope_prefix() {
	local cgroup max
	cgroup=$(cut -d: -f3- "/proc/$1/cgroup") || return 0
	[[ $cgroup == */run-*.scope ]] || return 0
	max=$(<"/sys/fs/cgroup$cgroup/memory.max") || return 0
	[[ $max == max ]] || printf 'systemd-run --user --scope -q -p MemoryMax=%s ' "$max"
}

# Resume command for claude process $1; fails if its session can't be identified.
claude_resume_command() {
	local pid=$1 sid="" start="" flag=--resume argv
	read -r sid start < <(jq -r 'select(.kind == "interactive") | "\(.sessionId) \(.procStart)"' \
		"$HOME/.claude/sessions/$pid.json" 2>/dev/null)
	[[ -n $sid && $start == "$(proc_start "$pid")" ]] || return 1
	compgen -G "$HOME/.claude/projects/*/$sid.jsonl" > /dev/null || flag=--session-id
	mapfile -td '' argv < "/proc/$pid/cmdline" || return 1
	printf '%sclaude %s %s%s' "$(scope_prefix "$pid")" "$flag" "$sid" "$(claude_keep_args "${argv[@]:1}")"
}

# zsh code that puts $1 on the next prompt's edit line without running it.
prefill() {
	printf "print -rz -- '%s'" "${1//\'/\'\\\'\'}"
}

# Programs resurrect re-runs, as " a b c ": its defaults plus @resurrect-processes, minus ~patterns.
safe_programs() {
	local list entry
	list=$(tmux show -gqv @resurrect-default-processes)
	list="${list:-vi vim view nvim emacs man less more tail top htop irssi weechat mutt} $(tmux show -gqv @resurrect-processes)"
	eval "set -- $list"
	printf ' '
	for entry; do [[ $entry == '~'* ]] || printf '%s ' "$entry"; done
}

main() {
	local save_file=$1 safe zsh="" line head cmd target pid child resume c
	local -a fields
	local -A pane_pids
	safe=$(safe_programs)
	[[ $(tmux show -gqv default-shell) == */zsh ]] && zsh=1  # restored panes run default-shell
	while IFS=$'\t' read -r target pid; do pane_pids[$target]=$pid; done \
		< <(tmux list-panes -a -F $'#{session_name}:#{window_index}.#{pane_index}\t#{pane_pid}')

	while IFS= read -r line; do
		if [[ $line != pane$'\t'* ]]; then printf '%s\n' "$line"; continue; fi
		head=${line%$'\t'*}
		cmd=${line##*$'\t':}  # last field minus resurrect's ":" prefix
		cmd=${cmd% }
		mapfile -td $'\t' fields < <(printf '%s' "$head")
		target="${fields[1]}:${fields[2]}.${fields[5]}"
		if [[ -n $cmd ]]; then
			child=""
			if [[ -n ${pane_pids[$target]:-} ]]; then
				for c in $(pgrep -P "${pane_pids[$target]}"); do
					[[ $(cat "/proc/$c/comm" 2>/dev/null) == claude ]] && child=$c
				done
			fi
			if [[ -n $child ]]; then
				if resume=$(claude_resume_command "$child"); then cmd=$resume
				elif [[ -n $zsh ]]; then cmd=$(prefill "$cmd"); fi
			elif [[ -n $zsh && $safe != *" ${cmd%% *} "* ]]; then
				cmd=$(prefill "$cmd")
			fi
		fi
		printf '%s\t:%s\n' "$head" "$cmd"
	done < "$save_file" > "$save_file.tmp" && mv -f "$save_file.tmp" "$save_file"
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
