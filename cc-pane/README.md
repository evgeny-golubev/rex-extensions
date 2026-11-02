# CC Pane for Rex

Opens a `Changes: <folder>` pane to the right of every pane that runs Claude
Code, and closes it when Claude exits or its pane closes. It stands in for
Claude Code's own diff panel; turn that one off with `"diffSidebarOpen": false`
in `~/.claude.json`.

![Activity, Context and Diff tabs, with made-up data](../docs/cc-pane.png)

The pane has these tabs, redrawn every 2 seconds:

| Tab | Section | What's in it |
| --- | --- | --- |
| **1 Activity** | Session | Title, branch, model, reasoning level, context size, how often it was compacted, and Claude's working time |
| | Files Claude edited | Newest first, with an edit count. ● means the file still has uncommitted changes, ○ that it doesn't |
| | Tests | The latest test runs and whether they passed. A run counts as a test by its command: `pytest`, `npm test`, `go test`, a script named test or spec |
| | Failed commands | The latest failures, with their first error line |
| **2 Context** | Open | Questions and plans waiting for your answer, questions at the end of Claude's last reply, and unfinished tasks |
| | From the last summary | The current state, next step and pending work from the latest compaction |
| | Decisions | Your answers, with any notes; plans you approved or rejected; actions you rejected, with what you said |
| | Requests | Your last 5 prompts, including slash commands and messages sent while Claude worked |
| **3 Diff** | | `git status` and `git diff --stat` against `HEAD`. Only shown in a git repository |

The pane uses the root of the repository Claude works in, or Claude's folder
outside one.

Press a tab's number, `Tab` or `←` `→` to switch. Scroll with the mouse
wheel, `j` / `k` or `↑` `↓`, `Space` / `b` or `Page Down` / `Page Up`, and
`g` for the top; the tab bar shows which lines are in view when they don't
all fit. Keys need the pane focused. The pane leaves the mouse to the
terminal, so dragging selects text as usual; the wheel reaches the pane as
arrow keys (the terminal's alternate scroll, mode 1007).

The Context and Activity tabs read Claude Code's own files and need no
Claude Code setting, hook or prompt: the Claude's session file
(`~/.claude/sessions/<pid>.json`, or under `$CLAUDE_CONFIG_DIR`) names its
transcript (`projects/<project>/<session>.jsonl`), which is read from where
the last read stopped. Nothing is sent anywhere, and no AI is involved, so
only what Claude Code records as structured data shows: a decision made in
plain conversation doesn't. Tests are recognised by their command: a test
runner (`pytest`, `jest`, …), a build tool's `test` command (`npm test`,
`go test`, `xcodebuild … test`, …) or a script file named test or spec. The
transcript format is Claude Code's own and undocumented, so an update to it
can empty these tabs.

Not a native Rex extension format: a config module launches a separate
event-driven `rex do` watcher, like cc-resume.

## Install

Place this directory at `~/.config/rex/extensions/cc-pane/` and add to
your Rex `init.lua`:

```lua
require("extensions.cc-pane")
```

Then run `rex config reload`. To load a changed `watcher.lua`, stop the running
watcher first:

```sh
pkill -f 'cc-pane/watcher\.lua'; rex config reload
```

## Palette actions

| Action | What it does |
|---|---|
| Show Changes Pane | Opens the pane beside the focused Claude, or another Claude in the tab that has none |
| Disable / Enable Changes Pane Auto-Show | Whether a pane opens by itself when Claude starts. On by default |

The choice is saved as `{"auto_show": false}` in `cc-pane/settings.json`, which
git ignores. It applies from the next Claude that starts, so open panes stay.
The palette shows whichever of Disable and Enable applies. For a key, bind
`cc_pane_show` or `cc_pane_auto_show` with `rex.bind`.

## Behavior

- Claude is recognised by its program name, `claude`, in the foreground or as
  the parent of the foreground command. A pane started as `rex split -- claude`
  is found by a second look a second after its shell starts.
- The changes pane takes 20% of the width, and focus stays on the Claude
  pane.
- The pane follows Claude's directory: after `/cd`, the Diff tab, the changed
  marks and the pane's label switch to the new directory's repository within
  a couple of seconds. The Diff tab covers the whole repository, not only the
  folder Claude is in.
- A changes pane you close stays closed until Claude starts again in that pane,
  or you run Show Changes Pane.
- When the watcher starts, it replaces leftover changes panes with new ones.
- cc-resume doesn't save changes panes; they come back with the resumed
  Claude.
- Errors go to `~/.config/rex/state/cc-pane.log`; the pane shows its
  own.

## Files

- `init.lua` starts the watcher and defines the palette actions.
- `settings.lua` reads and writes `settings.json`, and passes Show requests to
  the watcher through `show-request.json`.
- `watcher.lua` opens and closes the panes.
- `panel.lua` runs in each pane: reads git and the transcript, and draws
  the tabs.

## Tests

```sh
rex do ~/.config/rex/extensions/cc-pane/test.lua
```

The tests mock Rex and use a made-up transcript; they don't touch live
sessions.
