# CC Sidecar for Rex

Opens a `Sidecar: <folder>` pane to the right of every pane that runs Claude
Code, and closes it when Claude exits or its pane closes. It stands in for
Claude Code's own diff panel; turn that one off with `"diffSidebarOpen": false`
in `~/.claude.json`.

![The Changes tab on a pull request, Info with links and files from Claude's replies, and Log, with made-up data](../docs/cc-sidecar.png)

The pane has three tabs, redrawn every 2 seconds.

## Changes

The top row shows the branch, its added and removed lines, and `≣`, which
switches between a list and a folder tree. Below it are up to three scopes:

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
update to it can empty this scope and the Info and Log tabs.

## Info

Opens first. Open, Links and files, Tests and Failed commands fold; see
[Folding](#folding).

| Section | What's in it |
| --- | --- |
| **Session** | Title, branch, model, reasoning level, context size, how often it was compacted, and Claude's working time |
| **Usage** | Your 5-hour and 7-day limits and when they reset. Needs the status line step in the [main README](../README.md#install); hidden without it |
| **Open** | Questions and plans waiting for your answer, questions at the end of Claude's last reply, and unfinished tasks |
| **Links and files** | The files, images and links in Claude's last 3 final messages, as [Rex View](#rex-view) lists them. Click one to view it or open it in the browser, as Enter does there; **open panel** at the end opens Rex View's float |
| **Tests** | The latest test runs and whether they passed. A run counts as a test by its command: `pytest`, `npm test`, `go test`, a script named test or spec |
| **Failed commands** | The latest failures, with their first error line |

## Log

What was said and decided. Summary has its local date and time in its title.
The other three sections start each entry with theirs, run newest first and show
3 entries a page. All four fold.

| Section | What's in it |
| --- | --- |
| **Summary** | The current state, next step and pending work from the latest compaction |
| **Decisions** | Your answers, with any notes; plans you approved or rejected; actions you rejected, with what you said |
| **Requests** | Your prompts, including slash commands and messages sent while Claude worked. Up to 6 rows each |
| **Responses** | Claude's final text in each turn, which changes while the turn runs. Up to 8 rows each, read from the first 2,000 characters |

A section with more than one page ends with `← Next 2/10 Previous →`. Previous
goes to earlier entries and Next to later ones. Click them, or highlight the
section and press `]` or `[`. The page isn't saved.

## Rex View

Press `Cmd+Ctrl+Alt+Shift+O`, or run **Rex View: Open from Claude's Replies**
from the palette, to list what Claude's last 10 replies mention, newest first. A reply is
Claude's final message after one of your prompts, as in the Log tab's
Responses; what it wrote between tool calls doesn't count. It
reads the focused pane's Claude, or else the first Claude in the tab, and opens
over the tab in a float:

![Rex View's float with files, Jira keys, a pull request and a link, with made-up data](../docs/rex-view.png)

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

For a Claude in a directory, Rex View takes that directory's patterns, then its
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

### Replies read

Rex View's float reads the last 10 replies, and the Info tab's Links and files
section the last 3. To change them, set `"view_replies"` and `"info_replies"`
in `settings.json`, such as `{"view_replies": 20, "info_replies": 5}`. The float
reads only the last 16 MB of the transcript, and the section the last 10
replies.

## Where Info and Log get their data

Both tabs read Claude Code's own files and need no Claude Code setting, hook or
prompt: Claude's session file (`~/.claude/sessions/<pid>.json`, or under
`$CLAUDE_CONFIG_DIR`) names its transcript
(`projects/<project>/<session>.jsonl`), which is read from where the last read
stopped. Nothing is sent anywhere, and no AI is involved, so only what Claude
Code records as structured data shows: a decision made in plain conversation
doesn't.

## Folding

Click a section's heading to fold or unfold it, or highlight it with `n` and `p`
and press `Enter`. The choice is saved as `{"folded": {"Tests": true}}` in
`settings.json`, and applies to all sidecar panes within a couple of seconds.

## Keys and mouse

Click a tab, a scope, `≣`, a file, a section heading or a pager's side. Keys need
the pane focused:

| Key | What it does |
| --- | --- |
| `1` `2` `3`, `Tab`, `←` `→` | Switch tabs |
| `s` | Next scope |
| `t` | List or tree; the choice is saved in `settings.json` |
| `j` `k`, `↑` `↓` | Move the selection on Changes, through folders too in the tree; scroll on Info and Log |
| `n` `p` | Highlight the next or previous section on Info and Log |
| `[` `]` | Next and Previous page of the highlighted section on Log |
| `Enter` | On Changes, open the selected file's diff, or the first file's, or fold the selected folder. On Info and Log, fold the highlighted section |
| `Space` `b`, `Page Down` `Page Up` | Scroll a page |
| `g` | Back to the top |

The wheel scrolls. The pane takes clicks and drags for itself, so a plain drag
doesn't select text in it.

Not a native Rex extension format: a config module launches a separate
event-driven `rex do` watcher, like cc-resume.

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
| Rex View: Open from Claude's Replies | The [Rex View](#rex-view) list; also `Cmd+Ctrl+Alt+Shift+O` |
| Rex View: Set Editor | The command that [edits files](#editor) |
| Rex View: Edit Link Patterns | Adds, edits and deletes [link patterns](#link-patterns) |

The choice is saved as `{"auto_show": false}` in `cc-sidecar/settings.json`,
which git ignores. It applies from the next Claude that starts, so open panes
stay. The palette shows whichever of Disable and Enable applies. For a key, bind
`cc_sidecar_show` or `cc_sidecar_auto_show` with `rex.bind`. The Rex View
actions are `cc_sidecar_view`, `cc_sidecar_view_editor` and
`cc_sidecar_view_patterns`.

## Behavior

- Claude is recognised by its program name, `claude`, in the foreground or as
  the parent of the foreground command. A pane started as `rex split -- claude`
  is found by a second look a second after its shell starts.
- The pane takes 20% of the width, and focus stays on the Claude pane.
- The pane follows Claude's directory: after `/cd`, the scopes and the pane's
  label switch to the new directory's repository within
  a couple of seconds. They cover the whole repository, not only the folder
  Claude is in.
- A pane you close stays closed until Claude starts again in that pane, or you
  run Show Sidecar Pane.
- When the watcher starts, it replaces leftover sidecar panes with new ones,
  including `Changes:` panes from before this extension was renamed.
- cc-resume doesn't save sidecar panes; they come back with the resumed Claude.
- Errors go to `~/.config/rex/state/cc-sidecar.log`; the pane shows its own.

## Files

- `init.lua` starts the watcher, defines the palette actions and binds Rex
  View's key.
- `claude.lua` finds a pane's Claude and its transcript.
- `settings.lua` reads and writes `settings.json`, and passes Show requests to
  the watcher through `show-request.json`.
- `watcher.lua` opens and closes the panes.
- `panel.lua` runs in each pane: reads git and the transcript, and draws
  the tabs.
- `diff-view` draws one diff in the floating pane.
- `mentions.lua` finds the files, images and links in Claude's replies;
  `view-collect.lua` writes them as Rex View's list, and `view-picker` shows it.
- `view-settings` asks for the editor and edits the link patterns.

## Tests

```sh
rex do ~/.config/rex/extensions/cc-sidecar/test.lua
```

The tests mock Rex and use a made-up transcript; they don't touch live
sessions.
