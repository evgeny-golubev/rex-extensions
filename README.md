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

Rex loads these from `init.lua`. Each one's README covers its behaviour, state
files and logs (`~/.config/rex/state/`).

### cc-pane

A pane on the right, 20% of the tab, that opens and closes with Claude. It
replaces Claude Code's own diff panel.

Its three tabs, with made-up data:

![cc-pane's Activity, Context and Diff tabs](docs/cc-pane.png)

| Tab | Shows |
| --- | --- |
| **1 Activity** | Title, branch, model, context size, compactions and working time; files Claude edited (● while they have uncommitted changes); test runs; failed commands with their first error line |
| **2 Context** | Open questions, plans and tasks; your decisions and rejections, with what you said; your last 5 requests; where the last compaction summary left things |
| **3 Diff** | `git status` and `git diff --stat`, in a git repository |

| Keys | Action |
| --- | --- |
| `1` `2` `3`, `Tab`, `←` `→` | Switch tab |
| Wheel, `j` `k`, `↑` `↓` | Scroll |
| `Space` `b`, `Page Down` `Page Up` | Scroll a page |
| `g` | Back to the top |
| Drag | Select text |

[More about cc-pane](cc-pane/README.md).

### cc-crab-pond

A strip along the bottom 8% of each Claude tab. Here it's given room for three
rows, with sample crabs:

![cc-crab-pond](docs/cc-crab-pond.png)

Left to right:

- your 5-hour and weekly Claude limits, with the time to each reset;
- the tab's main Claude, dressed by model and effort (wizard, scientist,
  crown, cowboy, ninja, musician, gardener);
- a crab for each subagent, dressed by the job in its title (review →
  magnifying glass, debug → diving mask, git → flag, …);
- a crab for each background shell, monitor and program in the tab's other
  panes (editors, git, builds, servers, ssh); a failed command is on fire,
  an idle shell sleeps.

[More about cc-crab-pond](cc-crab-pond/README.md).

### cc-resume

Nothing on screen. After a reboot, update or crash, Rex brings back sessions,
tabs and splits, but not the programs that ran in them. cc-resume:

1. waits until Rex has finished restoring;
2. finds each pane that ran Claude Code, by tab and directory;
3. types `claude --resume <session>` into its shell, in the right directory,
   leaving alone any pane that's already running something;
4. recreates any session Rex didn't bring back.

[More about cc-resume](cc-resume/README.md).

## Skills

Claude Code plugins, installed through this repository's marketplace. Claude
uses them when you ask; they need nothing in `init.lua`.

### rex-view

Ask in your own words: "show me that screenshot", "open the README in a pane",
"show me where that function starts". The file opens in a floating pane over
the tab Claude is in.

| File | Shown as |
| --- | --- |
| png, jpg, gif, webp | The image, scaled to fit |
| Markdown, source code, other text | Line numbers and syntax colours from `bat`, at a given line if there is one |
| Binary | A short notice |

`q` closes it (`Esc` also works on an image). Without `bat`, text is plain,
with a notice saying how to install it.
[More about rex-view](plugins/rex-view/README.md).

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
