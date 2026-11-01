# Session Keeper for Rex

Saves every session's tabs, splits, labels and working directories, and brings
them back once after the Rex server restarts (reboot, update, crash). Panes that
were running Claude Code reopen with `claude --resume <session>` typed into a
shell, so the conversation continues in the same directory.

Not a native Rex extension format: a config module launches a separate
event-driven `rex do` watcher.

## Install

Place this directory at `~/.config/rex/extensions/session-keeper/` and add to
your Rex `init.lua`:

```lua
require("extensions.session-keeper")
```

Then run `rex config reload`. Every config load starts a watcher; a new one
quits when another is already connected, so to load a changed `watcher.lua`,
stop the running one first:

```sh
pkill -f 'session-keeper/watcher\.lua'; rex config reload
```

## Behavior and state

- Saves a second after a layout, label, directory or foreground-program change.
- Restores only when the snapshot comes from an earlier server run. Rex now
  brings sessions back itself, with their tabs and directories but not the
  programs in them, so the watcher first waits until the session list has
  stayed the same for 3 seconds (at most 20). Then:
  - a session that's still missing is created from the snapshot;
  - in a session Rex brought back, each pane that ran Claude Code is found
    again: the tab by its label or place, the pane by its directory or
    place. Once its shell is up, `claude --resume <session>` is typed into
    it, after a `cd` when the directory differs. A pane already running
    Claude or another program is left alone.

  The used snapshot is kept as `sessions.json.prev`.
- Claude Code is found through `~/.claude/sessions/<pid>.json`. Its original
  flags (model, permission mode) aren't known, so it resumes with defaults.
- Other programs (ssh, nvim) come back as a shell in their last directory.
- State: `~/.config/rex/state/sessions.json`; launcher errors go to
  `~/.config/rex/state/sessions.log`.

## Manual use

```sh
rex do --all ~/.config/rex/extensions/session-keeper/watcher.lua state=/tmp/x.json
```

## Tests

```sh
rex do ~/.config/rex/extensions/session-keeper/test.lua
```

The tests mock Rex around a temporary directory; they don't touch live
sessions or the real snapshot.
