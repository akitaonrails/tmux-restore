# tmux-restore

Reboot without losing your tmux. Every session, window, pane layout and scrollback comes back,
and panes that were running [Claude Code](https://claude.com/claude-code) reopen the same
conversations.

I built this after a reboot wiped 20 tmux windows, 17 of them Claude Code sessions.
[tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) and
[tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) do most of the work. This is
what it took on top of them:

- **Claude Code conversations come back.** Each pane running `claude` is saved as
  `claude --resume <session-id>` plus its original flags (model, effort, permission mode, ...).
  The id comes from Claude Code's per-process session registry, which follows `/clear`, so you
  get the conversation you were actually in, not the one the pane was started with.
- **A save at shutdown, not just on a timer.** A systemd user service holds a logind delay
  lock and saves the moment the machine announces a shutdown or reboot. Autosave every minute
  covers crashes and power loss.
- **Nothing unsafe re-runs by itself.** Allowlisted programs (editors, `htop`, `ssh`, `watch`,
  ...) restart. Anything else (`make deploy`, a dev server, a half-typed `rm`) comes back typed on
  the prompt, waiting for Enter (zsh).
- **No more squashed panes.** tmux-resurrect has a race: two restores running at once each "fix"
  a missing pane by splitting its window, leaving extra panes squashed to one line. Any login
  that runs `tmux start-server` before the real server (tmuxinator does) starts two restores.
  This setup installs resurrect from
  [a branch](https://github.com/andrewboldi/tmux-resurrect/tree/fix-concurrent-restore) that
  allows one restore at a time. The race is the likely cause of
  [tmux-resurrect#437](https://github.com/tmux-plugins/tmux-resurrect/issues/437).
- **Tests** that restore a real (anonymized) 29-window save on throwaway tmux servers,
  including the race.

## Install

Needs Linux with systemd, tmux (tested with 3.6), [TPM](https://github.com/tmux-plugins/tpm),
`jq`, `flock` and `gdbus`; zsh for the pre-typed commands; Claude Code (tested with 2.1.316) for
the conversations.

1. Clone this repo to `~/.tmux/tmux-restore` (the config and service expect that path):

   ```sh
   git clone https://github.com/andrewboldi/tmux-restore ~/.tmux/tmux-restore
   ```

2. Paste [`tmux.conf`](tmux.conf) into `~/.tmux.conf` above your
   `run '~/.tmux/plugins/tpm/tpm'` line. If you already use tmux-resurrect, replace its
   `@plugin` line and `rm -rf ~/.tmux/plugins/tmux-resurrect` so TPM fetches the fixed branch.
   Then `tmux source ~/.tmux.conf` and press prefix + <kbd>I</kbd>.

3. Save at shutdown:

   ```sh
   systemctl --user enable --now ~/.tmux/tmux-restore/systemd/tmux-shutdown-save.service
   systemd-inhibit --list | grep tmux-resurrect   # the delay lock should be listed
   ```

Try it: prefix + <kbd>Ctrl-s</kbd> to save, `tmux kill-server`, then start tmux again.

Edit `@resurrect-processes` in the pasted block to choose what restarts on its own.

## How it works

**Save.** Every minute continuum runs resurrect's save: layouts, each pane's directory and full
command line (read from `/proc`), and scrollback. Resurrect then calls
[`scripts/resurrect-post-save.sh`](scripts/resurrect-post-save.sh), which rewrites each pane's
saved command:

- `claude ...` becomes `claude --resume <id> <flags>`. The id is read from
  `~/.claude/sessions/<pid>.json` and checked against the process start time, so a recycled pid
  can't match. A session with no transcript yet gets `--session-id <id>`. The initial prompt is
  dropped, and flags that pick a conversation (`-c`, `--resume`, `--fork-session`, ...) are
  replaced. If claude ran in a memory-capped `systemd-run --user --scope`, the cap is kept.
- An allowlisted program stays as it is, and resurrect re-runs it.
- Anything else becomes `print -rz -- '<cmd>'`, which puts the command on zsh's prompt. With
  another shell it is left alone, so it isn't re-run.

**Shutdown.** [`scripts/tmux-shutdown-save.sh`](scripts/tmux-shutdown-save.sh) runs under
`systemd-inhibit --mode=delay` and watches logind's `PrepareForShutdown` signal. logind waits
for it while it saves, up to `InhibitDelayMaxSec`: 5 s by default, 30 s on Ubuntu with
unattended-upgrades installed. A save takes about 4 s here with 40 panes and long scrollback;
time yours with `time ~/.tmux/plugins/tmux-resurrect/scripts/save.sh quiet`, and if it gets
close to the limit, raise it (takes effect after a reboot):

```sh
sudo mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nInhibitDelayMaxSec=30\n' | sudo tee /etc/systemd/logind.conf.d/tmux-restore.conf
```

**Restore.** When the tmux server starts, continuum runs resurrect's restore: sessions,
windows, layouts and scrollback come back, then the allowed commands run, including each
`claude --resume`.

## The squashed-pane bug

After two reboots, a few windows came back with an extra pane, and the panes that belonged there
were one line tall. The minute-by-minute saves showed it happened at restore time.

`tmux start-server` starts a server, and continuum on it queues an auto-restore that runs a
second later. The server has no sessions, so it exits. Then the real server starts and queues
its own restore, and the orphaned one also lands on it: two restores, about 0.6 s apart.
Resurrect restores a pane with "pane missing, window exists: split the window", so both
restores split. After each split it runs `resize-pane -U 999` to make room for the next pane,
squashing the panes above to one line. Normally the saved layout is applied at the end and
evens them out, but a window with an extra pane no longer matches its saved layout, so tmux
rejects it ("have 3 panes but need 2") and the squash stays. The damage lands in the last
windows because the second restore skips the windows that already exist and catches up with
the first one near the end.

[`tests/restore-race.sh`](tests/restore-race.sh) restores a 29-window save twice at once.
Upstream tmux-resurrect got 2, 6 and 6 windows wrong in three runs; with the lock, none.
[`tests/login-replay.sh`](tests/login-replay.sh) replays the login itself: upstream starts two
restores, the fixed branch one.

## Tests

```sh
tests/hook-unit.sh             # claude flag handling, quoting, pre-typed commands
tests/shutdown-unit.sh         # the shutdown watcher, with fake gdbus/tmux
tests/restore-race.sh          # 29-window restore, two at once (or `single`), exact layouts
tests/login-replay.sh          # start-server + real server must restore once, exactly
```

They run on throwaway tmux servers (`tmux -L ...`) and never touch your sessions or saves. The
last two use the plugins in `~/.tmux/plugins` (override with `RESTORE=` or `PLUGINS_DIR=`).

## Limitations

- Linux only (`/proc`, logind). On macOS resurrect and continuum work, the extras don't.
- The Claude Code session registry is internal and undocumented. If it changes, claude panes
  come back as pre-typed commands instead of resumed conversations.
- A crash or power loss loses up to a minute.
- Programs are restarted, not checkpointed: Claude gets its conversation back, not a tool call
  that was running.

## License

MIT. tmux-resurrect and tmux-continuum are by Bruno Sutic and contributors.
