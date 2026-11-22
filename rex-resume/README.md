# Rex Resume

Brings back Claude Code and other programs after the Rex server restarts
(reboot, update, crash). Rex brings back sessions, tabs and splits itself, but
not the programs in them. This extension types `claude --resume <session>` into
each pane that ran Claude Code, so the conversation continues in the same
directory. It also types back the commands of other programs, such as
`nvim src/app.lua`, as [its settings](#settings) allow. It saves every
session's tabs, splits, labels and directories, so a session Rex didn't bring
back is recreated too.

Not a native Rex extension format: a config module launches a separate
event-driven `rex do` watcher.

## Install

Place this directory at `~/.config/rex/extensions/rex-resume/` and add to
your Rex `init.lua`:

```lua
require("extensions.rex-resume")
```

Then run `rex config reload`. Every config load starts a watcher; a new one
quits when another is already connected, so to load a changed `watcher.lua`,
stop the running one first:

```sh
pkill -f 'rex-resume/watcher\.lua'; rex config reload
```

Coming from cc-resume, its earlier name: change the `require` line, then run
`pkill -f 'cc-resume/watcher\.lua'; rex config reload`. The snapshot stays
where it was, so nothing is lost.

## Settings

An optional `settings.json` in this directory, kept out of git. It's read on
every save, so an edit applies without a restart.

```json
{
  "mode": "allow_full",
  "programs": ["nvim", "vim", "less", "htop"]
}
```

| `mode` | Brings back |
| --- | --- |
| `allow_full` (default) | Programs in `programs`, with their arguments: `nvim src/app.lua` |
| `allow_name` | Programs in `programs`, by name only: `nvim`. Arguments are never read |
| `any_full` | Any program that isn't a shell, with its arguments; `programs` is ignored |

Without `programs`, the list is nvim, vim, vi, nano, less, man, htop, btop,
top, watch, lazygit, tig, k9s and ssh. Claude Code always comes back, whatever
the mode or list.

Arguments come from `ps` and are saved as plain text in the snapshot, so in
`any_full` mode a token passed on a command line ends up there too. The other
modes only read the arguments of programs on the list. `ps` loses quoting, so
an argument with spaces in it comes back split in two.

## Behavior and state

- Saves a second after a layout, label, directory or foreground-program change.
- Restores only when the snapshot comes from an earlier server run. Rex now
  brings sessions back itself, with their tabs and directories but not the
  programs in them, so the watcher first waits until the session list has
  stayed the same for 3 seconds (at most 20). Then:
  - a session that's still missing is created from the snapshot;
  - in a session Rex brought back, each pane that ran a saved program is found
    again: the tab by its label or place, the pane by its directory or
    place. Once its shell is up, the command is typed into it, after a `cd`
    when the directory differs. A pane already running a program is left
    alone.

  The used snapshot is kept as `sessions.json.prev`.
- Claude Code is found through `~/.claude/sessions/<pid>.json`. Its original
  flags (model, permission mode) aren't known, so it resumes with defaults.
- A Codex conversation isn't resumed. `codex` isn't on the default list; add
  it to `programs` to start Codex again in its pane, in a new conversation.
- A program comes back as it was started, not as it was left: nvim reopens
  its files but not its buffers or undo history.
- Quitting a resumed program leaves the shell it was typed into.
- rex-sidecar and rex-crab-pond panes aren't saved. They reopen when Claude
  resumes.
- State: `~/.config/rex/state/sessions.json`; launcher errors go to
  `~/.config/rex/state/sessions.log`.

## Manual use

```sh
rex do --all ~/.config/rex/extensions/rex-resume/watcher.lua state=/tmp/x.json settings=/tmp/s.json
```

## Tests

```sh
rex do ~/.config/rex/extensions/rex-resume/test.lua
```

The tests mock Rex around a temporary directory; they don't touch live
sessions or the real snapshot.
