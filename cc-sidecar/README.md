# CC Sidecar for Rex

Opens a `Sidecar: <folder>` pane to the right of every pane that runs Claude
Code or Codex, and closes it when the agent exits or its pane closes. It stands
in for Claude Code's own diff panel; turn that one off with
`"diffSidebarOpen": false` in `~/.claude.json`. This page says Claude; a Codex
pane works the same, except for what [Codex doesn't
record](../agents/README.md#codex).

![The Changes tab on a pull request, the Info dashboard with permission checks, agents and background tasks, and Artifacts with documents, PRs, Jira issues and links from Claude's replies, with made-up data](../docs/cc-sidecar.png)

The pane has three tabs, redrawn every 2 seconds, and every second while a
clock runs. Their look follows [Flightdeck](https://github.com/scasella/claude-flightdeck),
a Claude Code mod: each section is a box in its own colour, gauges are cells, and
an empty section takes no room. Below 36 columns, boxes become plain headings.

## Changes

The header box shows the branch, its added and removed lines, and `≣`, which
switches between a list and a folder tree. Inside it are up to three scopes:

| Scope | What it lists | Where it comes from |
| --- | --- | --- |
| **Last Turn** | Files Claude edited since your last prompt | The hunks in Claude's transcript |
| **Uncommitted** | Staged and Unstaged groups; the tree merges them | `git status`, `git diff` |
| **PR** | Everything since the branch left the base of its open GitHub pull request, including uncommitted work; it takes Branch's place | `gh pr view` for the base, then `git diff` against the merge base with `origin/<base>`, or else `<base>` |
| **Branch** | Everything since the branch left `main`, including uncommitted work | `git diff` against the merge base with `origin/HEAD`, or else `main` or `master` |

On the default branch itself, which is where `origin/HEAD` points, or else `main`
or `master`, there's no Branch scope. PR and Branch show what they compare with,
such as `vs develop · #12`. The pull request needs [gh](https://cli.github.com),
signed in. It's looked up when you open Changes, when the branch or repository
changes, and every 5 minutes while Changes stays open; without `gh`, or offline,
the scope is Branch.

Click a file or press `Enter` to read its diff in a floating pane; `q` closes it.
With [delta](https://github.com/dandavison/delta) installed, the code is
highlighted in the file's language, old and new sit side by side when the pane
has 120 columns or more, and delta's own git settings apply. Without it, [bat](https://github.com/sharkdp/bat) colours the added and removed lines.
The tab's count is the number of uncommitted files.

The tree lists folders before files at each level. Click a folder or select it
and press `Enter` to fold or unfold it; a folded folder shows how many files it
holds. The choice is saved in `settings.json`, for each repository.

Last Turn only knows Claude's Edit and Write tools, so files changed through
Bash (`sed`, a formatter) don't show up there. Outside a git repository it's the
only scope. The transcript format is Claude Code's own and undocumented, so an
update to it can empty this scope and the Info and Artifacts tabs.

## Info

Opens first. Every box folds; see [Folding](#folding).

| Box | What's in it |
| --- | --- |
| **Model · main** | Running or idle; the session's title and branch; reasoning effort, permission mode and how many requests Claude made; context against the model's window, and ⟲ with how often it was compacted; your 5-hour and 7-day limits with the time to each reset (↻), and Claude's working time |
| **ADVISOR** | The advisor tool's consults on a timeline from your first prompt, how long ago the last one was and how long it took. Shown only once Claude consults it |
| **GATE** | A dotted cell (`⣿`) for each latest permission check: green allowed by a rule or the mode, cyan by the auto-mode classifier, blue by you, red ✗ denied, dim made inside a subagent. Then the totals, and the checks by family: click `file`, `shell` or `other`, or press `f`, `s` or `o`, to list that family's last 5 checks |
| **AGENTS** | The latest 8 subagents as lanes on one time axis, newest first, each with its time. A running one has a pulsing lavender ● and a ticking clock. One that isn't marked finished but hasn't changed for 5 minutes, such as an idle team member, is shown idle with a grey ○. Click a lane for its type, context, steps, last 3 tool calls and the start of its answer |
| **PROCESSES** | Claude's background tasks that run right now, as Claude Code's own list shows them, newest first: a monitor by its description, a background shell by its command, with values that look like credentials masked. Each has a pulsing ● and its kind, green for a shell and blue for a monitor, and how long it has run. A task counts until a notification in the transcript ends it, a monitor's timeout passes, or no shell of Claude's that started with it is left; only executable names are read from `ps`. Hidden while none run |
| **OPEN** | Questions and plans waiting for your answer, questions at the end of Claude's last reply, and unfinished tasks |
| **Receipt** | The running turn, or the last one: how long, the agents it started, and its edits and errors. Then tests and failed commands: click either for the latest 8. A run counts as a test by its command: `pytest`, `npm test`, `go test`, a script named test or spec |
| **LOG** | Your prompts, agents starting and finishing, edits, failed commands, denied permission checks and advisor consults, each with its time. It fills the rows under the other boxes, or, when they fill the screen, a screen of its own below them |

The context window and the limits come from the status line step in the
[main README](../README.md#install); without them they're left out. Commands and
paths in GATE, the lanes, the receipt and the log have values that look like
credentials masked as `•••`: the value of a `TOKEN=`, `--password` or
`Authorization:`, a bearer token, and long key-like strings.

## Artifacts

What all of Claude's replies in this session mention, newest first. A reply is
Claude's final message after one of your prompts; what it wrote between tool
calls doesn't count. **Search Panel**, pinned at the top, opens the
[Search Panel](#search-panel). The tab's title shows how many rows there are, counting a PR once.

| Section | What's in it |
| --- | --- |
| **Documents** | Files that exist with `md`, `txt`, `pdf`, `html`, `csv`, `rtf`, `doc`, `docx`, `xlsx`, `pptx` or `svg`, and images |
| **PRs** | Links to a GitHub pull request (`/pull/12`) or a GitLab merge request (`/merge_requests/12`) |
| **Jira** | Links to a Jira issue (`/browse/KEY-12`) |
| **URLs** | Other `http` and `https` links |
| **Other** | Other files that exist, such as source code, with an optional `:line` |

[Link patterns](#link-patterns) turn text such as `SHOP-12` or `#12` into PRs
and Jira links. A category with nothing in it isn't shown, and each one folds. Each shows its
newest 10 rows; a last row says how many more there are and opens the Search
Panel.
Click a row to open it as Enter does in the Search Panel: a file or image in the
viewer, in a float, and a link in your browser. Something mentioned again is
listed once, where it was mentioned last. At most 1,000 rows are listed.

PRs are listed one row a PR, named by its number, in grey, and its title. A PR mentioned through more
than one link, such as its page, a comment and its files, has those links under
it: a comment as `# 123`, and other links by their last part, such as `files` or
`commit abc1234`. Click the PR to open it, or a link under it to open that.
Titles come from GitHub through [gh](https://cli.github.com), up to 4 at a time
while the tab is open, and each is looked up once; without `gh`, or for a GitLab
merge request, a PR shows its repository and number. The Search Panel lists each
link, such as `acme/shop#42 # 123`, without titles.

Jira issues show their key, in grey, and their title, as a reply wrote it next
to the key: a Markdown link's text, words in brackets after it (`SHOP-12 (Cart
rounding)`), after a colon or dash, or in the next table cell. A later mention
without one keeps an earlier title. Nothing is looked up, so an issue no reply
named shows its key and site.

git and gh run in the background, so the pane keeps taking keys and clicks while
they do. A scope you switch to shows "Loading…" until git is done, and a PR's
title appears when gh returns it.

Each reply is read once, as it comes in. All of them are read again when Claude
changes directory or you change the link patterns.

## Search Panel

Press `Cmd+Ctrl+Alt+Shift+O`, run **Rex View: Search Panel** from the palette,
or click **Search Panel** on the Artifacts tab, to list what all of Claude's
replies mention, as on the [Artifacts](#artifacts) tab: by category, newest
first, with each category's icon and colour, and its name after each row. The
float is styled as the sidecar's boxes: a teal frame labelled with the count,
the keys at the top, an orange pointer and gold matches. The key reads the focused pane's
Claude, or else the first Claude in the tab. The list opens over the tab in a
float:

![The Search Panel's float with files, Jira keys, a pull request and a link, with made-up data](../docs/rex-view.png)

| Row | Enter | `Ctrl+E` |
| --- | --- | --- |
| A text file that exists: absolute, `~/`, or relative to Claude's directory, with an optional `:line` | Views it in the [rex-view](../plugins/rex-view/README.md) viewer, at the line | Edits it in your editor, in the float |
| An image: png, jpg, gif or webp | Views it | Views it |
| An `http` or `https` link | Opens it in your browser | Opens it |
| Text that a link pattern matches | Opens the link it makes | Opens it |

Type to filter. `Ctrl+Y` copies the path or link, and `Esc` closes the list.
Folders aren't listed. It needs [fzf](https://github.com/junegunn/fzf) for the
list; without it, rows are numbered and you type one. Each float replaces the
one before, including a rex-view float Claude opened.

### Editor

**Rex View: Set Editor** asks for the command `Ctrl+E` runs, such as `nvim`,
`code -w` or `subl -w`; the file is added at the end. Without one, it's
`$VISUAL`, then `$EDITOR`, then `vim`. It's saved as `"editor"` in
`settings.json`.

### Link patterns

A link pattern turns text in a reply into a link: a Jira key, or a pull request
number. Each one is locked to a directory, and applies to Claudes working in it
or below it; `/` is every project. **Rex View: Edit Link Patterns** lists them by
directory; Enter edits one, `Ctrl+A` adds one and `Ctrl+D` deletes one. A new
one starts with the directory of the tab's Claude. There are none until you add
them. They're saved in `settings.json`, as the directory, then a
[Lua pattern](https://www.lua.org/manual/5.1/manual.html#5.4.1) and the link
basis that the match is added to:

```json
{
  "link_patterns": {
    "/": {
      "%W(%u+%-%d+)": "https://acme.atlassian.net/browse/"
    },
    "/Users/you/Sites/acme": {
      "%W#(%d+)": "https://github.com/acme/web/pull/",
      "acme/web#(%d+)": "https://github.com/acme/web/pull/",
      "web!(%d+)": "https://gitlab.com/acme/web/-/merge_requests/"
    },
    "/Users/you/Sites/acme/mobile": {
      "%W(%u+%-%d+)": "https://acme-mobile.atlassian.net/browse/"
    }
  }
}
```

For a Claude in a directory, cc-sidecar takes that directory's patterns, then its
parent's, and so on up to `/`, and uses them all. When two set the same
pattern, the nearer one wins. With the example, `PROJ-12` opens
`https://acme-mobile.atlassian.net/browse/PROJ-12` under `acme/mobile`, and
`https://acme.atlassian.net/browse/PROJ-12` everywhere else. `acme/web#45` and
`#45` open a pull request only under `acme`, and not in `acme-old`, since directories
match whole path parts.

A pattern with a capture adds only the capture, so `acme/web#45` opens
`https://github.com/acme/web/pull/45`. In Lua patterns `%` escapes, so a dash is
`%-`, `%d` is a digit and `%u` a capital letter. A basis must start with
`http://` or `https://`. A pattern that isn't valid matches nothing.

Rex's Lua doesn't match `%f` word boundaries, so start a pattern with `%W`, a
character that isn't a letter or digit, and capture what follows: `%W(TF%-%d+)`
matches `TF-12` but not the `TF-8` in `UTF-8`, and `%W#(%d+)` matches `#12` but
not `repo#12`. A reply is matched with a line break before and after it, so
`%W` matches at its start and end too. The `#` rule in the example is locked to
`acme`, where a bare `#12` means that repository's pull request.

## Where Info and Artifacts get their data

Both tabs read Claude Code's own files and need no Claude Code setting, hook or
prompt: Claude's session file (`~/.claude/sessions/<pid>.json`, or under
`$CLAUDE_CONFIG_DIR`) names its transcript
(`projects/<project>/<session>.jsonl`), which is read from where the last read
stopped. Subagents are read from the `subagents` folder beside it, the status
line's saved input from `state/statusline/<session>.json`, and Claude's live
shells from `ps`, by executable name only. PR titles come from `gh`; nothing
else is sent anywhere, and no AI is involved, so only what Claude Code records
as structured data shows: a decision made in plain conversation doesn't.

For a Codex, the session is its thread in `~/.codex/state_<n>.sqlite`, found
as [agents/README.md](../agents/README.md#codex) describes, and the transcript
is the thread's rollout. Subagents are the threads it spawned, and the usage
limits come from the rollout that changed last.

## Folding

Click a box's top line to fold or unfold it, or highlight it with `n` and `p`
and press `Enter`; a folded box is one line. The choice is saved as `{"folded": {"Gate": true}}` in
`settings.json`, and applies to all sidecar panes within a couple of seconds.

## Keys and mouse

Click a tab, a scope, `≣`, a file, a box's top line, a gate family, an agent
lane, tests or failed commands, an Artifacts row or Search Panel. Keys need
the pane focused:

| Key | What it does |
| --- | --- |
| `1` `2` `3`, `Tab`, `←` `→` | Switch tabs |
| `s` | Next scope on Changes |
| `f` `s` `o` | On Info, list the last file, shell or other permission checks |
| `t` | List or tree; the choice is saved in `settings.json` |
| `j` `k`, `↑` `↓` | Move the selection on Changes, through folders too in the tree; scroll on Info and Artifacts |
| `n` `p` | Highlight the next or previous section on Info and Artifacts |
| `Enter` | On Changes, open the selected file's diff, or the first file's, or fold the selected folder. On Info and Artifacts, fold the highlighted section |
| `Space` `b`, `Page Down` `Page Up` | Scroll a page |
| `g` | Back to the top |

The wheel scrolls. The pane takes clicks and drags for itself, so a plain drag
doesn't select text in it.

Not a native Rex extension format: a config module launches a separate
event-driven `rex do` watcher, like rex-resume.

## Install

Place this directory at `~/.config/rex/extensions/cc-sidecar/` and add to
your Rex `init.lua`:

```lua
require("extensions.cc-sidecar")
```

Then run `rex config reload`. To load a changed `watcher.lua`, stop the running
watcher first:

```sh
pkill -f 'cc-sidecar/watcher\.lua'; rex config reload
```

## Palette actions

| Action | What it does |
|---|---|
| Show Sidecar Pane | Opens the pane beside the focused Claude, or another Claude in the tab that has none |
| Disable / Enable Sidecar Pane Auto-Show | Whether a pane opens by itself when Claude starts. On by default |
| Rex View: Search Panel | The [Search Panel](#search-panel); also `Cmd+Ctrl+Alt+Shift+O` |
| Rex View: Set Editor | The command that [edits files](#editor) |
| Rex View: Edit Link Patterns | Adds, edits and deletes [link patterns](#link-patterns) |

The choice is saved as `{"auto_show": false}` in `cc-sidecar/settings.json`,
which git ignores. It applies from the next Claude that starts, so open panes
stay. The palette shows whichever of Disable and Enable applies. For a key, bind
`cc_sidecar_show` or `cc_sidecar_auto_show` with `rex.bind`. The Rex View
actions are `cc_sidecar_view`, `cc_sidecar_view_editor` and
`cc_sidecar_view_patterns`.

## Behavior

- Claude is recognised by its program name, `claude`, and Codex by `codex`, in
  the foreground or as the parent of the foreground command. A pane started as `rex split -- claude`
  is found by a second look a second after its shell starts.
- The pane takes 30% of the width, and focus stays on the Claude pane.
- The pane follows Claude's directory: after `/cd`, the scopes and the pane's
  label switch to the new directory's repository within
  a couple of seconds. They cover the whole repository, not only the folder
  Claude is in.
- A pane you close stays closed until Claude starts again in that pane, or you
  run Show Sidecar Pane.
- When the watcher starts, it replaces leftover sidecar panes with new ones,
  including `Changes:` panes from before this extension was renamed.
- rex-resume doesn't save sidecar panes; they come back with the resumed Claude.
- Errors go to `~/.config/rex/state/cc-sidecar.log`; the pane shows its own.

## Files

- `init.lua` starts the watcher, defines the palette actions and binds Rex
  View's key.
- `../agents/` finds a pane's agent, its session and its subagents.
- `parsers/claude.lua` and `parsers/codex.lua` read each agent's transcript
  into the state the tabs draw.
- `settings.lua` reads and writes `settings.json`, and passes Show requests to
  the watcher through `show-request.json`.
- `watcher.lua` opens and closes the panes.
- `panel.lua` runs in each pane: reads git, `gh`, `ps` and the transcript in
  background tasks, so keys work while they run, and draws the tabs.
- `diff-view` draws one diff in the floating pane.
- `mentions.lua` finds the files, images and links in Claude's replies;
  `view-collect.lua` writes them as the Search Panel's list, and `view-picker`
  shows it.
- `view-settings` asks for the editor and edits the link patterns.

## Tests

```sh
rex do ~/.config/rex/extensions/cc-sidecar/test.lua
```

The tests mock Rex and use a made-up transcript; they don't touch live
sessions.
