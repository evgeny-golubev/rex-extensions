# Rex extensions and skills for Claude Code

Make the [Rex](https://www.superlogical.com) terminal a better home for
[Claude Code](https://claude.com/claude-code) on macOS: see what each Claude is
doing and what you decided with it, watch your agents as pixel crabs, get your
conversations back after a restart, and let Claude show you files.

| | Name | What you get | Runs as |
| --- | --- | --- | --- |
| Extension | [cc-pane](#cc-pane) | A side pane with each Claude's activity, open questions, decisions and uncommitted changes | Pane beside Claude |
| Extension | [cc-crab-pond](#cc-crab-pond) | Claudes, subagents and background jobs as animated crabs, plus your usage limits | Strip along the tab's bottom |
| Extension | [cc-resume](#cc-resume) | Claude Code conversations resumed after the Rex server restarts | Background watcher |
| Skill | [rex-view](#rex-view) | Claude shows images, Markdown and source code in a floating pane | Plugin, version 0.1.0 |

**Contents:** [Extensions](#extensions) · [Skills](#skills) ·
[Requirements](#requirements) · [Install](#install) · [Update](#update) ·
[Repository layout](#repository-layout) · [Privacy](#privacy) ·
[Tests](#tests) · [License](#license)

## Extensions

Rex loads these from `init.lua`. Each one's README has the details.

### cc-pane

Answers "what has this Claude done, and what's still waiting on me?" A pane on
the right, 20% of the tab, opens and closes with Claude and replaces Claude
Code's own diff panel.

![cc-pane's Activity, Context and Diff tabs, with made-up data](docs/cc-pane.png)

**Activity** lists the session's facts, edited files, test runs and failed
commands. **Context** lists open questions, your decisions and your last
requests. **Diff** shows the uncommitted changes.
[Tabs, keys and limits →](cc-pane/README.md)

### cc-crab-pond

Shows everything running in a tab at a glance. A strip along the bottom 8% of
each Claude tab draws your usage limits, then one animated crab per Claude,
subagent, background job and program in the tab's other panes. Colour shows the
kind of program, the hat shows its job, and a failed command is on fire. Shown
here with room for three rows and sample crabs:

![cc-crab-pond](docs/cc-crab-pond.png)

It needs one setup step: [saving Claude Code's status line input](#extensions-1).
[How to read the crabs →](cc-crab-pond/README.md)

### cc-resume

Gets your Claude conversations back after a reboot, Rex update or crash. Rex
restores sessions, tabs and splits but not the programs in them, so cc-resume
types `claude --resume <session>` into each pane that ran Claude. It has nothing
on screen. [How it works and what it can't restore →](cc-resume/README.md)

## Skills

Claude Code plugins, installed through this repository's marketplace. Claude
uses them when you ask; they need nothing in `init.lua`.

### rex-view

Ask Claude to show a file, in your own words: "show me that screenshot" or "open
the README in a pane". Images, Markdown and source code open in a floating pane
over Claude's tab, and `q` closes it. [Details →](plugins/rex-view/README.md)

## Requirements

| Needed for | What |
| --- | --- |
| Everything | macOS with [Rex](https://www.superlogical.com) and [Claude Code](https://claude.com/claude-code) |
| cc-crab-pond | A terminal font with Unicode 16 octant characters (Rex draws them itself), and `jq` for the status line (`brew install jq`) |
| rex-view colours, optional | [`bat`](https://github.com/sharkdp/bat) (`brew install bat`) |

## Install

### Extensions

1. Clone the repository anywhere and link it into Rex's config folder:

   ```sh
   git clone https://github.com/evgeny-golubev/rex-extensions.git ~/Sites/utils/rex
   ln -s ~/Sites/utils/rex ~/.config/rex/extensions
   ```

2. Add the ones you want to `~/.config/rex/init.lua`:

   ```lua
   require("extensions.cc-resume")
   require("extensions.cc-pane")
   require("extensions.cc-crab-pond")
   ```

3. Load them:

   ```sh
   rex config reload
   ```

4. For cc-pane, turn off Claude Code's own diff panel by setting
   `"diffSidebarOpen": false` in `~/.claude.json`.

5. For cc-crab-pond, have Claude Code's status line command save its input,
   which gives the crabs their names, models, outfits, subagents and your
   usage limits. Add these lines after your status line script reads stdin
   into `$input`:

   ```bash
   sid=$(echo "$input" | jq -r '.session_id // empty')
   [ -n "$sid" ] && mkdir -p ~/.claude/state/statusline && printf '%s' "$input" > ~/.claude/state/statusline/"$sid".json
   ```

   No status line yet? See
   [cc-crab-pond's setup](cc-crab-pond/README.md#claude-code-status-line) for a
   complete script and the `settings.json` entry.

### Skills

```sh
claude plugin marketplace add evgeny-golubev/rex-extensions
claude plugin install rex-view@rex-extensions
```

Then restart Claude Code, or run `/reload-plugins` in it.

## Update

Extensions: pull, then restart the watchers.

```sh
git -C ~/.config/rex/extensions pull
pkill -f 'extensions/.*/watcher\.lua'; rex config reload
```

Skills:

```sh
claude plugin marketplace update rex-extensions
claude plugin update rex-view@rex-extensions
```

## Repository layout

```text
.claude-plugin/marketplace.json   the plugin marketplace
cc-resume/                    extension
cc-pane/                     extension
cc-crab-pond/                        extension
plugins/rex-view/                 skill, as a plugin
docs/                             pictures
```

## Privacy

Everything reads Claude Code's own files and the process list on your machine.
Nothing is sent anywhere and no AI is involved.

## Tests

```sh
rex do ~/.config/rex/extensions/cc-resume/test.lua
rex do ~/.config/rex/extensions/cc-pane/test.lua
rex do ~/.config/rex/extensions/cc-crab-pond/test.lua
rex do ~/.config/rex/extensions/plugins/rex-view/test.lua
```

The tests mock Rex and don't touch live sessions.

## License

MIT. The crab art is redrawn after
[crab-band](https://github.com/MaxHarfen/crab-band) (MIT); see
[LICENSE](LICENSE).
