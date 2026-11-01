# shellcheck shell=bash
# Codex CLI (https://github.com/openai/codex)
#
# Reopens the exact conversation. While it runs, Codex's native process keeps the conversation's
# rollout file open: ~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl. Before anything is
# typed there's no such file yet, and the pane starts a fresh codex.

# shellcheck disable=SC2034 # read by keep_flags and first_word (scripts/lib.sh)
codex_value_flags="-c --config --enable --disable --remote --remote-auth-token-env -m --model --local-provider -p --profile -s --sandbox -C --cd --add-dir -a --ask-for-approval"
codex_variadic_flags="-i --image"
codex_drop_flags="--last --all --include-non-interactive -i --image"

codex_exact=1 # the rollout file is the conversation
codex_match() {
	[[ $(proc_comm "$1") == codex || $(proc_name "$1") == codex ]] && proc_args "$1" || return 1
	# Subcommands other than resume and fork aren't the interactive TUI.
	case $(first_word codex "${ARGV[@]}") in
	exec | e | review | login | logout | mcp | plugin | mcp-server | app-server | remote-control | app | completion | update | doctor | sandbox | debug | execpolicy | apply | a | cloud | cloud-tasks | responses-api-proxy | stdio-to-uds | exec-server | features | help) return 1 ;;
	esac
}

# The process that owns the conversation: the native codex binary. npm installs start it from
# a node wrapper, so look one level down too.
codex_native() {
	local c
	[[ $(proc_comm "$1") == codex ]] && { printf '%s\n' "$1"; return 0; }
	for c in $(proc_children "$1"); do
		[[ $(proc_comm "$c") == codex ]] && { printf '%s\n' "$c"; return 0; }
	done
	return 1
}

# Prints the path of the rollout file (the newest, if a /new or /fork left several open).
codex_session() {
	local native f m meta newest="" newest_m=0
	native=$(codex_native "$1") || return 1
	while IFS= read -r f; do
		f=${f% (deleted)}
		[[ $f == */sessions/*/rollout-*.jsonl && -f $f ]] && m=$(file_mtime "$f") || continue
		# Only your own conversations: not sub-agents, not `codex exec`.
		meta=$(head -1 "$f" | jq -r '.payload | "\(.source) \(.thread_source // "user")"' 2> /dev/null)
		[[ $meta == "cli user" || $meta == "vscode user" ]] || continue
		if ((m > newest_m)); then
			newest=$f
			newest_m=$m
		fi
	done < <(proc_open_files "$native")
	[[ -n $newest ]] && printf '%s\n' "$newest"
}

codex_resume() {
	local id cwd keep
	id=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<< "${2##*/}" | tail -1)
	[[ -n $id ]] && proc_args "$1" || return 1
	keep=$(keep_flags codex "${ARGV[@]}")
	# Started from another directory, codex would ask which one to use; -C answers.
	if ! flag_value "-C --cd" "${ARGV[@]}" > /dev/null; then
		cwd=$(head -1 "$2" | jq -r '.payload.cwd // empty' 2> /dev/null)
		[[ -n $cwd ]] && keep=" -C $(printf '%q' "$cwd")$keep"
	fi
	printf 'codex resume %s%s' "$id" "$keep"
}

# No conversation yet (nothing typed): start a fresh one with the same flags.
codex_continue() {
	proc_args "$1" || return 1
	printf 'codex%s' "$(keep_flags codex "${ARGV[@]}")"
}
