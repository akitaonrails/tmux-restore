#!/usr/bin/env bash
# Unit test for scripts/shutdown-save.sh with fake gdbus, tmux and save.sh: saves on
# PrepareForShutdown and exits 0; ignores other signals; exits 1 (so systemd restarts it) when
# the monitor ends without a shutdown.
set -u
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin" "$D/home/.tmux/plugins/tmux-resurrect/scripts"
printf '#!/bin/sh\ncat "%s/signals"\n' "$D" > "$D/bin/gdbus"
printf '#!/bin/sh\n[ "$1" = show ] && cat "%s/save-path"\nexit 0\n' "$D" > "$D/bin/tmux"
printf '#!/bin/sh\necho "$0 $*" >> "%s/saves"\n' "$D" | tee "$D/save.sh" > "$D/home/.tmux/plugins/tmux-resurrect/scripts/save.sh"
chmod +x "$D/bin/"* "$D/save.sh" "$D/home/.tmux/plugins/tmux-resurrect/scripts/save.sh"
pass=0 fail=0
check() { if [[ $2 == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: [%s]\n  got:  [%s]\n' "$1" "$2" "$3"; fi; }
run() {  # $1 = signals the fake monitor prints, $2 = @resurrect-save-script-path
	printf '%s\n' "$1" > "$D/signals"; printf '%s' "$2" > "$D/save-path"; : > "$D/saves"
	out=$(HOME="$D/home" PATH="$D/bin:$PATH" "$here/../scripts/shutdown-save.sh" --locked); rc=$?
}
shutdown="/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForShutdown (true,)"
run "$shutdown" "$D/save.sh"
check "shutdown: exit" 0 "$rc"; check "shutdown: saves via option path" "$D/save.sh quiet" "$(cat "$D/saves")"
check "shutdown: log line" "tmux sessions saved before shutdown" "$out"
run "$shutdown" ""
check "no option: default path" "$D/home/.tmux/plugins/tmux-resurrect/scripts/save.sh quiet" "$(cat "$D/saves")"
run "${shutdown/true/false}"$'\n'"/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)" "$D/save.sh"
check "other signals: exit" 1 "$rc"; check "other signals: no save" "" "$(cat "$D/saves")"
echo "passed=$pass failed=$fail"; (( fail == 0 ))
