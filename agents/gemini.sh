# shellcheck shell=bash
# Gemini CLI (https://github.com/google-gemini/gemini-cli)
#
# Gemini writes one JSONL file per session under ~/.gemini/tmp/<project>/chats/ and doesn't
# record which process has which one open. This picks the newest session of the process's
# project that started after the process did and that you've typed in, and only when no other
# gemini works in that directory. Otherwise it uses the session the process was started with
# (--resume or --session-id). A session nobody typed in starts fresh.

# shellcheck disable=SC2034 # read by keep_flags and first_word (scripts/lib.sh)
gemini_value_flags="-m --model -p --prompt -i --prompt-interactive --approval-mode -o --output-format --session-file --session-id --policy --admin-policy --allowed-mcp-server-names --allowed-tools -e --extensions --include-directories"
gemini_optional_flags="-r --resume -w --worktree --delete-session"
gemini_drop_flags="-r --resume --session-id --session-file -i --prompt-interactive -w --worktree --list-sessions --delete-session -l --list-extensions"

# The id of the "environment context" message Gemini writes into every new session.
gemini_env_context=d04923d38bb0f6017037e74183378ef4

gemini_match() {
	[[ $(proc_name "$1") == gemini ]] && proc_args "$1" || return 1
	# Not the subcommands, headless runs (-p), ACP, listings, or the sandbox.
	case $(first_word gemini "${ARGV[@]}") in mcp | extensions | extension | skills | skill | hooks | hook | gemma) return 1 ;; esac
	local arg
	for arg in "${ARGV[@]}"; do
		case $arg in -p | --prompt | --prompt=* | --acp | --experimental-acp | -l | --list-extensions | --list-sessions | --delete-session | -v | --version | -h | --help | -s | --sandbox) return 1 ;; esac
	done
}

# Gemini relaunches itself as a child node process; that one is the interactive session.
gemini_tui() {
	local c
	for c in $(proc_children "$1"); do
		[[ $(proc_name "$c") == gemini ]] && { printf '%s\n' "$c"; return 0; }
	done
	printf '%s\n' "$1"
}

gemini_typed_in() { grep '"type":"user"' "$1" 2> /dev/null | grep -qv "$gemini_env_context"; }

gemini_session() {
	local tui home cwd since slug f start best="" best_start=0
	tui=$(gemini_tui "$1")
	if alone_in_cwd "$tui" && cwd=$(proc_cwd "$tui") && since=$(proc_start_epoch "$tui"); then
		home=$(proc_env "$tui" GEMINI_CLI_HOME)
		home=${home:-$HOME}/.gemini
		slug=$(jq -r --arg d "$cwd" '.projects[$d] // empty' "$home/projects.json" 2> /dev/null)
		for f in "$home/tmp/$slug/chats"/session-*.jsonl; do
			[[ -n $slug && -f $f ]] || continue
			start=$(iso_epoch "$(head -1 "$f" | jq -r '.startTime // empty' 2> /dev/null)") || continue
			((start >= since && start > best_start)) && gemini_typed_in "$f" || continue
			best=$f
			best_start=$start
		done
	fi
	if [[ -n $best ]]; then
		head -1 "$best" | jq -r '.sessionId // empty'
	elif proc_args "$1"; then
		flag_value "-r --resume --session-id" "${ARGV[@]}" | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
	fi
}

gemini_resume() {
	proc_args "$1" || return 1
	printf 'gemini --resume %s%s' "$2" "$(keep_flags gemini "${ARGV[@]}")"
}

# Nothing typed yet: start a fresh session with the same flags.
gemini_continue() {
	proc_args "$1" || return 1
	printf 'gemini%s' "$(keep_flags gemini "${ARGV[@]}")"
}
