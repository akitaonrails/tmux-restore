# shellcheck shell=bash
# pi (https://github.com/badlogic/pi-mono)
#
# pi writes one JSONL file per session under ~/.pi/agent/sessions/--<directory>--/ and doesn't
# record which process has which one open. This picks the file for the process's directory that
# was written most recently since the process started, and only when no other pi works in that
# directory. pi hides its own command line, so its flags can't be kept.

pi_match() {
	# pi renames its process to "pi" (macOS shows that in its arguments, not its name).
	[[ $(proc_comm "$1") == pi || $(proc_name "$1") == pi ]] || return 1
	# Not Debian's /usr/bin/pi, which prints digits of pi: the agent runs on node (or bun).
	local exe
	exe=$(proc_exe "$1")
	[[ -z $exe || ${exe##*/} == node* || ${exe##*/} == bun* ]]
}

pi_session() {
	local dir cwd since enc f m newest="" newest_m=0
	alone_in_cwd "$1" && cwd=$(proc_cwd "$1") && since=$(proc_start_epoch "$1") || return 1
	dir=$(proc_env "$1" PI_CODING_AGENT_DIR)
	dir=${dir:-$HOME/.pi/agent}
	enc=${cwd#/}
	enc=${enc//[\/\\:]/-}
	for f in "${dir/#\~/$HOME}/sessions/--$enc--"/*.jsonl; do
		[[ -f $f ]] && m=$(file_mtime "$f") || continue
		if ((m >= since && m > newest_m)); then
			newest=$f
			newest_m=$m
		fi
	done
	[[ -n $newest ]] && printf '%s\n' "$newest"
}

pi_resume() { printf 'pi --session %q' "$2"; }

pi_continue() { printf 'pi -c'; }
