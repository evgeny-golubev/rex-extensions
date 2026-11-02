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

**Answers "what has this Claude done, and what's still waiting on me?"** without
scrolling back through the conversation.

A pane on the right, 20% of the tab, opens by itself when Claude starts in a
pane and closes when Claude exits. Focus stays on Claude. It replaces Claude
Code's own diff panel.

![cc-pane's Activity, Context and Diff tabs, with made-up data](docs/cc-pane.png)

The tabs redraw every 2 seconds:

| Tab | Section | What's in it |
| --- | --- | --- |
| **1 Activity** | Session | Title, branch, model, context size, how often it was compacted, and Claude's working time |
| | Files Claude edited | Newest first, with an edit count. ● means the file still has uncommitted changes, ○ that it doesn't |
| | Tests | The latest test runs and whether they passed. A run counts as a test by its command: `pytest`, `npm test`, `go test`, a script named test or spec |
| | Failed commands | The latest failures, with their first error line |
| **2 Context** | Open | Questions and plans waiting for your answer, questions at the end of Claude's last reply, and unfinished tasks |
| | Decisions | Your answers, with any notes; plans you approved or rejected; actions you rejected, with what you said |
| | Requests | Your last 5 prompts, including slash commands and messages sent while Claude worked |
| | From the last summary | The current state, next step and pending work from the latest compaction |
| **3 Diff** | | `git status` and `git diff --stat` against `HEAD`. Only shown in a git repository |

| Keys | Action |
| --- | --- |
| `1` `2` `3`, `Tab`, `←` `→` | Switch tab |
| Wheel, `j` `k`, `↑` `↓` | Scroll |
| `Space` `b`, `Page Down` `Page Up` | Scroll a page |
| `g` | Back to the top |
| Drag | Select text |

Keys need the pane focused. Everything comes from what Claude Code records in
its transcript, so a decision made in plain conversation, not through a question
or plan prompt, doesn't appear under Decisions. The transcript format is
undocumented, so a Claude Code update can empty the Activity and Context tabs.

[More about cc-pane](cc-pane/README.md).

### cc-crab-pond

**Shows everything running in a tab at a glance:** which Claude, how close you
are to your limits, what its subagents and background jobs are doing, and what
just failed.

A strip along the bottom 8% of each tab that runs Claude. It opens with the
first Claude in the tab and closes with the last. Here it's given room for three
rows, with sample crabs:

![cc-crab-pond](docs/cc-crab-pond.png)

**Usage limits** sit on the far left: your 5-hour and weekly Claude limits, each
with the percentage used and the time to its reset (`↺`). The bar is green, turns
yellow at 70% and red at 90%.

**Every other crab is one thing running in the tab.** Read it in four parts:

| Part | Tells you | In the picture |
| --- | --- | --- |
| Body colour | What kind of thing it is | Blue is an editor, violet a server |
| Hat and prop | Its job, or for a Claude its model and effort | The wrench on `bun` means build or test |
| Movement | Its state | See the states below |
| Three lines of text | Its name, then its model, type or folder, then how long it's been running | `Rate-limit guard`, `Opus 5.5`, `up 1h12m` |

**The first crab is the tab's main Claude:** the focused Claude pane, or the last
one that was. It shows the session name, model and uptime, and its outfit shows
the model and effort:

| Model | Outfit |
| --- | --- |
| Fable | Wizard |
| Opus, effort max | Scientist |
| Opus, effort xhigh | Painter |
| Opus, effort high | Crown |
| Opus, effort medium or unknown | Cowboy |
| Opus, effort low | Ninja |
| Sonnet | Musician |
| Haiku | Gardener |

**Subagents** are lighter peach, titled with the task Claude gave them. The first
word of their type or task that names a job picks the outfit, matched at the
start of a word, so "reviewing" counts as "review". With no match they get a
random outfit, which stays the same for that task.

| Words such as | Outfit |
| --- | --- |
| search, find, explore, research | Explorer |
| plan, architect, spec | Clipboard |
| review, audit, check, verify | Magnifying glass |
| build, test, fix, implement | Hard hat and wrench |
| code, edit, refactor, rewrite | Sunglasses and a screen |
| git, commit, merge, PR | Flag |
| server, docker, API, deploy | Server rack |
| debug, trace, crash, bug | Diving mask |
| agent, automate, script | Robot antenna |
| analyse, benchmark, measure | Scientist |
| design, UI, CSS, layout | Painter |
| docs, README, write, summarise | Musician |
| clean, remove, upgrade, migrate | Gardener |
| quick, small, simple | Ninja |
| lead, coordinate, manage | Crown |
| generate, convert, transform | Wizard |

**Background shells, monitors and the programs in the tab's other panes** are
coloured by what the program does. Other Claudes in the tab appear under their
session names.

| Colour | Kind | Outfit | Programs |
| --- | --- | --- | --- |
| Sky blue | Claude's monitor | Magnifying glass | Claude watching a command's output |
| Blue | Editor | Sunglasses and a screen | nvim, vim, helix, emacs, nano, zed |
| Red | Git | Flag | git, gh, lazygit, tig, jj |
| Yellow | Build or test | Hard hat and wrench | go, cargo, make, npm, bun, node, python, pytest, xcodebuild |
| Violet | Server | Server rack | docker, kubectl, psql, redis, nginx, terraform |
| Purple | Remote | Diving mask | ssh, mosh, scp, rsync, tailscale |
| Teal | Agent CLI | Robot antenna | codex, gemini, aider, opencode, goose |
| Green | Anything else | None | |
| Gray | Shell | Nightcap | zsh, bash, fish |

**A crab's state shows in how it moves:**

| You see | It means |
| --- | --- |
| Bobbing, stepping and waving | Busy, with its uptime on the last line |
| Faded, eyes shut, with a drifting `Z` | Idle or waiting. A shell's second line says `zzz`, or `✓ zzz` if its last command succeeded |
| On fire, with `exit 2!` | The shell's last command failed, with that exit code |

**Crowded tabs stay readable.** Identical crabs merge into one with a count, such
as `docker ×2` or `waiting ×3`, showing the longest uptime, and waiting crabs come
last. A taller pane wraps the crabs onto more rows. When they still don't fit, a
plain gray crab with `+N` counts the rest.

**It needs one setup step.** Session names, models, effort, limits and subagents
come from Claude Code's status line, which has to save its input
([step 5 of Install](#extensions-1)). Without that, Claude crabs are plain, and limits and
subagents are missing. Background jobs come from the process list, and only
executable names are read, never arguments, which can hold secrets.

[More about cc-crab-pond](cc-crab-pond/README.md).

### cc-resume

**Gets your Claude conversations back after a reboot, Rex update or crash.** Rex
brings back sessions, tabs and splits, but not the programs that ran in them, so
without this you'd have a tab of empty shells. It has nothing on screen.

| When | What it does |
| --- | --- |
| While you work | About a second after a layout, label, directory or program changes, saves every session to `~/.config/rex/state/sessions.json`, with the conversation ID of each Claude |
| After the server restarts | Waits until the session list has been stable for 3 seconds, at most 20 |
| | Finds each pane that ran Claude: the tab by label or position, the pane by directory or position |
| | Once that pane's shell is ready, types `claude --resume <session>`, with a `cd` first if the directory differs |
| | Recreates any session Rex didn't bring back, with its tabs and splits |

It restores once per server run, and keeps the snapshot it used as
`sessions.json.prev`. Panes already running something are left alone.

Limits to know:

- Claude resumes with default flags, because the model and permission mode it
  started with aren't known.
- Other programs, such as ssh or nvim, come back as a shell in their last
  directory.
- cc-pane and cc-crab-pond panes aren't saved. They reopen when Claude resumes.

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
