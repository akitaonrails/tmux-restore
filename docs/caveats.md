# Caveats

**Platforms.** Everything is tested on Linux. On macOS, tmux itself comes back and the agent
adapters read processes through `ps` and `lsof`, but that path hasn't been tested with real
agents, and there's no save at shutdown (the minute-by-minute save still runs).

**Power loss and crashes** lose up to a minute: whatever happened since the last save.

**Programs restart; they aren't checkpointed.** An agent gets its conversation back, not a tool
call or command it was running at the time.

**Agent session files are internal.** Adapters read files the agents don't document. If an agent
changes them, its panes fall back to "continue the latest conversation in this directory", or to
a pre-typed command.

**Pre-typed commands need zsh.** With another shell, a command that isn't safe to re-run comes
back as an empty prompt.

**Same agent, same directory.** Gemini CLI, opencode and pi don't record which process has which
conversation open, so tmux-restore tells their panes apart by directory and start time. Two panes
running the same one of them in the same directory come back as commands typed on the prompt,
rather than both opening the same conversation. Claude Code and Codex are always exact.

**Gemini CLI before 0.47** has a bug: a session resumed twice with nothing typed in between comes
back empty (the conversation is still on disk). Update Gemini CLI.

**Agents' own prompts still show.** Codex asks about updates on start, for example; a restored
pane waits at that prompt like a fresh start would.

**The tmux-resurrect fork.** Until
[tmux-resurrect#600](https://github.com/tmux-plugins/tmux-resurrect/pull/600) is merged, the
installer points tmux-resurrect at a fork with the concurrent-restore fix. If your
tmux-resurrect checkout has local changes, the installer leaves it alone and you don't get the fix.

**Saving at shutdown has a time limit.** logind waits for the save up to `InhibitDelayMaxSec`:
5 s by default, 30 s on Ubuntu with unattended-upgrades. A save with 40 panes and long scrollback
takes about 4 s. To check yours, run
`time ~/.tmux/plugins/tmux-resurrect/scripts/save.sh quiet`. To raise the limit (it takes effect
after a reboot):

```sh
sudo mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nInhibitDelayMaxSec=30\n' | sudo tee /etc/systemd/logind.conf.d/tmux-restore.conf
```

**Your tmux config gets a block** between `# >>> tmux-restore >>>` and `# <<< tmux-restore <<<`.
The installer keeps your original as `tmux.conf.before-tmux-restore`. To undo everything:

```sh
curl -fsSL https://raw.githubusercontent.com/andrewboldi/tmux-restore/main/install.sh | bash -s -- --uninstall
```

**Manual install**, without the installer: add these above TPM's `run` line, press prefix + I,
then enable the service with
`systemctl --user enable --now ~/.tmux/plugins/tmux-restore/systemd/tmux-restore.service`.

```tmux
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'andrewboldi/tmux-resurrect#fix-concurrent-restore'
set -g @plugin 'andrewboldi/tmux-restore'
set -g @plugin 'tmux-plugins/tmux-continuum'   # last: it skips restoring while other plugins load
set -g @continuum-restore 'on'
```
