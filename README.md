# Rex extensions and agent skills

Tools that make the [Rex](https://www.superlogical.com) terminal a better home
for coding agents on macOS. They work with
[Claude Code](https://claude.com/claude-code), and the extensions work with
[Codex](https://github.com/openai/codex) too.

- **See what your agent did.** A side pane shows the files it changed, a live
  dashboard of its work, and every link and document it mentioned.
- **Keep your day in view.** Your Google Tasks or Apple Reminders sit in the
  same pane, and the agent can report work done for you to confirm.
- **Watch everything at once.** Every agent, subagent and program in a tab
  shows up as a pixel crab.
- **Lose nothing on a restart.** After a reboot, your conversations and
  programs come back in their panes.
- **Let the agent show you things.** Pictures, reports and code open in a
  floating pane.

| | Name | What you get | Runs as |
| --- | --- | --- | --- |
| Extension | [rex-sidecar](#rex-sidecar) | What the agent changed, a dashboard of its work, what its replies mention, and your tasks | A pane beside the agent |
| Extension | [rex-crab-pond](#rex-crab-pond) | Agents, subagents and programs as animated crabs | A strip along the tab's bottom |
| Extension | [rex-resume](#rex-resume) | Claude Code and Codex conversations, and programs like nvim, back after a restart | A background watcher |
| Skill | [rex-view](#rex-view) | Claude shows pictures, Markdown and code in a floating pane | Plugin 0.5.1 |
| Skill | [rex-sidecar-task-list](#rex-sidecar-task-list) | Claude keeps your task list in step with the work you do together | Plugin 0.2.0 |

**Contents:** [Extensions](#extensions) · [Skills](#skills) ·
[Install](#install) · [Update](#update) · [Requirements](#requirements) ·
[Privacy](#privacy) · [Repository layout](#repository-layout) ·
[Tests](#tests) · [Changelog](CHANGELOG.md) · [License](#license)

## Extensions

Rex loads extensions from its `init.lua`. Each one has its own README with the
details.

### rex-sidecar

Answers two questions: what did the agent change, and what's still waiting on
you? The pane opens on the right of every Claude Code or Codex pane and closes
when the agent exits.

![rex-sidecar with made-up data. Info: the model, context, limits, permission checks, subagents, running shells, open questions and the last turn. Changes: the files changed on a pull request. Artifacts: documents, PRs, Jira issues, links and files from the agent's replies. Reminders: the day's tasks, rated A, B and C.](docs/rex-sidecar.png)

| Tab | What it shows |
| --- | --- |
| **Info** | The model, context and limits, every permission check, subagents on a timeline, running shells, open questions, the last turn and a session log |
| **Changes** | The files changed in the last turn, the uncommitted work, or the branch or its pull request. Click one to read its diff |
| **Artifacts** | The documents, PRs, Jira issues and links the agent's replies mention. The **Search Panel** (`Cmd+Ctrl+Alt+Shift+O`) lists them all in a float |
| **Google Tasks** and **Reminders** | Your day's work, rated A, B and C, with estimates and a daily review. Hidden until you show them |

![The Search Panel float, listing files, Jira keys, pull requests and links, with made-up data](docs/rex-view.png)

[Tabs, keys and setup →](rex-sidecar/README.md)

### rex-crab-pond

Shows everything running in a tab at a glance. A strip along the bottom of the
tab draws one crab for each agent, subagent, background job and program. The
colour shows what kind of program it is, the hat shows its job, and a failed
command sets it on fire.

![rex-crab-pond with sample crabs](docs/rex-crab-pond.png)

It needs one setup step: [saving Claude Code's status line input](#install).
[How to read the crabs →](rex-crab-pond/README.md)

### rex-resume

Rex brings back your sessions, tabs and splits after a restart, but not the
programs in them. rex-resume types them back in: `claude --resume` for Claude
Code, `codex resume` for Codex, and the original command for programs like
nvim. It has nothing on screen.

![rex-resume: a tab's panes before a restart, the saved snapshot, and the same panes after the restart with their commands typed back in, with made-up data](docs/rex-resume.png)

[Settings and limits →](rex-resume/README.md)

## Skills

Skills are Claude Code plugins, installed from this repository. Claude uses
them when they fit what you ask. They need nothing in `init.lua`.

### rex-view

Ask Claude to show you a file: "show me that screenshot" or "open the README
in a pane". It opens in a floating pane over Claude's tab, and `q` closes it.

[Details →](plugins/rex-view/README.md)

### rex-sidecar-task-list

When you start work with Claude, it adds the work to your task list, or finds
the task already there. When the work is done, Claude reports it, and you
confirm with one key in the sidecar. It works with the Google Tasks and
Reminders tabs. To set it up, ask Claude "set up the sidecar Tasks tab".
[Details →](plugins/rex-sidecar-task-list/README.md)

## Install

### Extensions

1. Clone the repository and link it into Rex's config folder:

   ```sh
   git clone https://github.com/evgeny-golubev/rex-extensions.git ~/Sites/utils/rex
   ln -s ~/Sites/utils/rex ~/.config/rex/extensions
   ```

2. Add the extensions you want to `~/.config/rex/init.lua`:

   ```lua
   require("extensions.rex-resume")
   require("extensions.rex-sidecar")
   require("extensions.rex-crab-pond")
   ```

3. Load them:

   ```sh
   rex config reload
   ```

4. For rex-sidecar: turn off Claude Code's own diff panel. Set
   `"diffSidebarOpen": false` in `~/.claude.json`.

5. For rex-crab-pond, and for the context and limits in rex-sidecar: make
   Claude Code's status line save its input. Add these lines to your status
   line script, after it reads its input into `$input`:

   ```bash
   sid=$(echo "$input" | jq -r '.session_id // empty')
   [ -n "$sid" ] && mkdir -p ~/.claude/state/statusline && printf '%s' "$input" > ~/.claude/state/statusline/"$sid".json
   ```

   No status line yet? [rex-crab-pond's setup](rex-crab-pond/README.md#claude-code-status-line)
   has a complete script and the `settings.json` entry.

### Skills

```sh
claude plugin marketplace add evgeny-golubev/rex-extensions
claude plugin install rex-view@rex-extensions
claude plugin install rex-sidecar-task-list@rex-extensions
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
claude plugin update rex-sidecar-task-list@rex-extensions
```

### Coming from older versions

- **Renamed extensions.** cc-sidecar is now rex-sidecar, cc-crab-pond is now
  rex-crab-pond, and cc-resume is now rex-resume. Change the `require` lines
  in your `init.lua`, then run the update commands above. Your settings move
  with the folders. Key bindings to their actions need the new names, such as
  `rex_sidecar_view` for `cc_sidecar_view`.
- **The Tasks tab is now two tabs**, Google Tasks and Reminders. The first
  time the sidecar opens, your old tab's place and state move to the tab of
  the source you used.
- **The task skill is renamed.** Replace the old plugin:

  ```sh
  claude plugin uninstall sidecar-task-list@rex-extensions
  claude plugin marketplace update rex-extensions
  claude plugin install rex-sidecar-task-list@rex-extensions
  ```

## Requirements

| For | You need |
| --- | --- |
| Everything | macOS, [Rex](https://www.superlogical.com) and [Claude Code](https://claude.com/claude-code) |
| Codex panes | The [Codex](https://github.com/openai/codex) CLI. Its sessions are read with the `sqlite3` that comes with macOS |
| rex-crab-pond | A terminal font with Unicode 16 octant characters (Rex draws them itself), and `jq` (`brew install jq`) |
| Context and limits in rex-sidecar | The status line step above, with `jq` |
| Highlighted diffs | [`delta`](https://github.com/dandavison/delta) (`brew install git-delta`); without it, [`bat`](https://github.com/sharkdp/bat) colours them |
| Colours in rex-view | [`bat`](https://github.com/sharkdp/bat) (`brew install bat`) |
| Formatted Markdown in rex-view | [`glow`](https://github.com/charmbracelet/glow) (`brew install glow`) |
| The Search Panel | [`fzf`](https://github.com/junegunn/fzf) (`brew install fzf`), and `jq` |
| PR scope and PR titles | [`gh`](https://cli.github.com), signed in (`brew install gh`, `gh auth login`) |

Everything except the first two rows is optional; the feature it powers is
left out without it.

## Privacy

Everything runs on your Mac and reads local files: Claude Code's and Codex's
own files and the list of running programs. rex-resume, and rex-sidecar and
rex-crab-pond for Codex, also read the command lines of programs. No AI is
involved.

Nothing is sent anywhere, with two exceptions you choose: the Google Tasks tab
talks to Google's Tasks API, and the PR scope and titles ask GitHub through
`gh`. Reminders stay on your Mac, apart from Apple's own sync.

## Repository layout

```text
.claude-plugin/marketplace.json   the plugin marketplace
agents/                           Claude Code and Codex adapters
rex-sidecar/                      extension
rex-crab-pond/                    extension
rex-resume/                       extension
plugins/rex-view/                 skill, as a plugin
plugins/rex-sidecar-task-list/    skills, as a plugin
docs/                             pictures
```

## Tests

```sh
rex do ~/.config/rex/extensions/agents/test.lua
rex do ~/.config/rex/extensions/rex-sidecar/test.lua
rex do ~/.config/rex/extensions/rex-crab-pond/test.lua
rex do ~/.config/rex/extensions/rex-resume/test.lua
rex do ~/.config/rex/extensions/plugins/rex-view/test.lua
```

The tests mock Rex and don't touch live sessions.

## License

MIT. The crab art is redrawn after
[crab-band](https://github.com/MaxHarfen/crab-band) (MIT); see
[LICENSE](LICENSE).
