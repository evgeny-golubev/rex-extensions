# Rex extensions for Claude Code

Three extensions for the [Rex](https://www.superlogical.com) terminal on macOS
that make it a better home for Claude Code:

| Extension | What it does |
| --- | --- |
| [session-keeper](session-keeper/) | Saves every session's tabs and splits, and brings them back after the Rex server restarts, resuming Claude Code conversations. |
| [changes-pane](changes-pane/) | A side pane next to each Claude with tabs for its activity, the session's open questions and decisions, and the uncommitted git changes. |
| [crab-pond](crab-pond/) | A strip along the bottom of each Claude tab showing the Claudes, subagents and background jobs there as animated pixel crabs, plus your usage limits. |

They read Claude Code's own files and the process list. Nothing is sent
anywhere and no AI is involved.

## What they look like

### changes-pane

A pane on the right, 30% of the tab, beside the Claude pane:

```text
 1 Activity   2 Context   3 Diff                     1–24 of 41

Session
Title       Add rate-limit guard to embeddings
Branch      feat/rate-limit
Model       claude-opus-5-5
Context     86k tokens
Compacted   1×
Claude time 42m

Files Claude edited 3
  ● src/embeddings/guard.ts ×4
  ● src/embeddings/guard.test.ts ×2
    README.md

Tests
  ✓ bun test guard
  ✗ bun test
```

```text
 1 Activity   2 Context   3 Diff

Open
? Should the guard also cover batch requests?
▸ Update the README

Decisions
✓ Which limit should apply?
  → 60 requests a minute
✗ Rejected Bash: rm -rf dist
  “keep the build output”

Requests last 5 of 12
› add a rate-limit guard to the embedding actions
```

Switch tabs with `1` `2` `3`, `Tab` or `←` `→`. Scroll with the wheel,
`j` `k`, `↑` `↓`, `Space` `b` or `g`. Drag to select text.

### crab-pond

A strip along the bottom 8% of each Claude tab. Here it's given room for
three rows, with sample crabs:

![crab-pond](docs/crab-pond.png)

Left to right:

- your 5-hour and weekly Claude limits, with the time to each reset;
- the tab's main Claude, dressed by model and effort (wizard, scientist,
  crown, cowboy, ninja, musician, gardener);
- a crab for each subagent, dressed by the job in its title (review →
  magnifying glass, debug → diving mask, git → flag, …);
- a crab for each background shell, monitor and program in the tab's other
  panes (editors, git, builds, servers, ssh); a failed command is on fire,
  an idle shell sleeps.

### session-keeper

Nothing on screen. After a reboot, update or crash it reopens your sessions,
tabs and splits in their directories, and types
`claude --resume <session>` in panes that ran Claude Code.

## Requirements

- macOS with [Rex](https://www.superlogical.com) installed.
- [Claude Code](https://claude.com/claude-code) for changes-pane and
  crab-pond.
- A terminal font with Unicode 16 octant characters for crab-pond (Rex draws
  them itself).
- `jq`, for crab-pond's status line line (`brew install jq`).

## Install

1. Clone into Rex's config folder:

   ```sh
   git clone https://github.com/evgeny-golubev/rex-extensions.git ~/.config/rex/extensions
   ```

2. Add the ones you want to `~/.config/rex/init.lua`:

   ```lua
   require("extensions.session-keeper")
   require("extensions.changes-pane")
   require("extensions.crab-pond")
   ```

3. Load them:

   ```sh
   rex config reload
   ```

4. For changes-pane, turn off Claude Code's own diff panel by setting
   `"diffSidebarOpen": false` in `~/.claude.json`.

5. For crab-pond, have Claude Code's status line command save its input,
   which gives the crabs their names, models, outfits, subagents and your
   usage limits. Add these lines after your status line script reads stdin
   into `$input`:

   ```bash
   sid=$(echo "$input" | jq -r '.session_id // empty')
   [ -n "$sid" ] && mkdir -p ~/.claude/state/statusline && printf '%s' "$input" > ~/.claude/state/statusline/"$sid".json
   ```

   No status line yet? See
   [crab-pond's setup](crab-pond/README.md#claude-code-status-line) for a
   complete script and the `settings.json` entry.

To update, `git -C ~/.config/rex/extensions pull`, then restart the watchers:

```sh
pkill -f 'extensions/.*/watcher\.lua'; rex config reload
```

Each extension's README covers its behaviour, state files and logs
(`~/.config/rex/state/`).

## Tests

```sh
rex do ~/.config/rex/extensions/session-keeper/test.lua
rex do ~/.config/rex/extensions/changes-pane/test.lua
rex do ~/.config/rex/extensions/crab-pond/test.lua
```

The tests mock Rex and don't touch live sessions.

## License

MIT. The crab art is redrawn after
[crab-band](https://github.com/MaxHarfen/crab-band) (MIT); see
[LICENSE](LICENSE).
