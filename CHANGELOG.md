# Changelog

Releases are tagged `vX.Y.Z` on GitHub. The skills keep their own versions,
in each plugin's `plugin.json`.

## v1.5.0 — 2026-11-26

The sidecar and crab panes get toggles: one palette action shows a pane or
hides it.

### rex-sidecar and rex-crab-pond

- **Toggle Sidecar Pane** and **Toggle Crabs Pane** replace the Show actions.
  Rex reads action titles only when it loads the config, so a Show action
  could never offer Hide. Toggle Sidecar Pane closes the focused agent's
  sidecar, or the sidecar you're in, and otherwise opens one as before.
  Toggle Crabs Pane closes the tab's crab pane when it has one.
- **Renamed actions:** a key bound with `rex.bind` to `rex_sidecar_show` or
  `rex_crab_pond_show` needs `rex_sidecar_toggle` or `rex_crab_pond_toggle`.

## v1.4.1 — 2026-11-26

Crab ponds draw again with the current Rex, and the sidecar's PROCESSES box
leaves out polls of Hub runs.

### Fixes

- **Crab ponds were empty:** Rex no longer sets `REX_SESSION` in a pane and
  now requires a session ID to view one, so the pond never found its tab. The
  pond and sidecar find their session from the pane instead. The sidecar's
  tab view (hiding in a background tab, a Hub float's state) works again too.
- **A tab could get no pond:** when the sidecar and pond opened in a tab at
  the same moment, the pond's split could vanish under it. It now tries again
  a second later.
- **PROCESSES leaves out Hub polls:** a background task that runs
  `rex do hub_…` to wait for a Hub run isn't listed, since the HUB box shows
  that run.

## v1.4.0 — 2026-11-26

rex-hub, a new extension: one agent runs another in a minimized floating
pane, with its own HUB box in the sidecar. Advisor consults from subagents and
team members now count, and the task tabs show a selected task's whole name.

### rex-hub (new)

- **Delegate to another agent CLI:** Claude Code, Codex, agy, Pi or OpenCode
  runs another of them with `rex do hub_run`, in a minimized float in the
  same tab, instead of a blind shell command. Open it any time to watch,
  approve or steer it.
- **Two modes:** `oneshot` runs one task and returns its answer; the float
  closes when the agent ends. `interactive` runs the agent's full interface
  for a back-and-forth with `hub_send` and `hub_read`, until `hub_stop`.
- **Answers as Markdown:** a oneshot run's answer is saved as `<id>.md` and
  opens in leaf like an artifact; its errors go to `<id>.err`.
- **Waiting and time limits:** Rex ends a `rex do` action after 30 seconds,
  so `hub_run` waits up to 25 and otherwise returns the run's `id` to poll
  with `hub_status`. A oneshot run is ended as `timeout` after `timeout`
  seconds (default 600), even when nobody polls.
- **Status you can trust:** `done`, `failed`, `stopped` (also when you close
  the float) or `timeout`, with the exit code, from a record the run writes
  once. Run files of runs that ended more than 7 days ago are pruned.
- **The rex-hub skill:** a plugin for Claude Code, also linkable into agy,
  that has the agent use Hub when you ask it to consult or hand work to
  another agent. The agent's own subagents still run the usual way.

### rex-sidecar

- **HUB box:** the pane's Hub runs, newest first: the agent in its colour,
  the task, its mode and time, and ● running, ✓ done, red ✗ failed or timed
  out, or dim ■ stopped. Click a run for **Open**, **Stop**, **View output**
  and the start of its answer. Hidden while there are none.
- **ADVISOR:** consults by subagents and team members count too, as a dim
  `◇` beside Claude's own `♦`, with how many came from subagents. A
  subagent's consult also shows in its lane's tool calls.
- **PROCESSES:** the box no longer blinks away for a moment while the
  sidecar checks which background tasks still run.
- **Tasks:** the selected task shows its whole name, wrapped under the first
  line, and stays in view at the bottom of the pane. The README has optional
  steps for each agent to keep the task list without being asked. Thanks to
  Timofei Bogoliubov
  ([#12](https://github.com/evgeny-golubev/rex-extensions/pull/12)).
- Hub floats don't get a sidecar of their own.

### rex-crab-pond and rex-resume

- Hub floats don't open a second pond, and aren't saved in resume snapshots.

## v1.3.1 — 2026-11-24

Fixes to v1.3.0.

- **rex-sidecar:** after the Mac slept, every pane's clock fell behind by the
  time it slept. The clock, turn timers, advisor times and running subagents'
  times were wrong, and a running subagent showed `0:00`. The pane now keeps
  to the wall clock.
- **rex-sidecar:** Claude team members (agents started with a name, in the
  background) show as done (✓) once they have reported to Claude, instead of
  a grey ○ forever. Claude Code never marks them finished.
- **rex-sidecar:** the LOG no longer says `done` the moment a team member or
  background subagent starts. It says so when the team member reports idle,
  or the background subagent's task ends.

## v1.3.0 — 2026-11-23

A clearer LOG for all five agents, shared agent colours in the sidecar and
the pond, a much lighter CPU and memory footprint, Code Mode support, and the
rex-view plugin retired.

### rex-sidecar

- **LOG:** a calmer icon and colour per kind, for Claude, Codex, agy, Pi and
  OpenCode alike: `$` commands, `✓` passing tests, `◦` reads and searches,
  `↗` and `◎` web pages and searches, `⬡` MCP tools (`server·tool`), `▷`
  workflows and `♦` advisor consults, besides prompts, writes, edits,
  deletes, subagents, errors and compactions.
  - A command shows the agent's description of it, when there is one; click
    the row to see the command itself.
  - Two or more reads in a row fold into `▸ read N files` or `▸ explored N`,
    and a click opens them. Read-only shell commands count as reads, even
    when joined with `&&`, `;` or `|`.
  - Leading `cd ... &&` and `name=...;` parts are dropped, and your home and
    the project folder are shortened.
  - `sleep`, `rex session rename`, Claude's reads of its own spilled tool
    output and Code Mode's `REPL` wrappers are left out.
- **Code Mode:** a Claude session in Code Mode shows `code` before the
  running or idle dot.
- **Main box:** the branch (`⎇`) is read live from git, and a linked worktree
  shows as `⑂` with its name. Effort and mode lose their labels.
- **Turn box:** while a turn runs, it animates at about 60 frames a second,
  patched in place, without the old 2-second stalls.
- **Tab settings:** Info is listed too and can be moved, with `J` `K`,
  `Shift+↑` `Shift+↓` or a click on `↑` `↓`. It still can't be hidden.
- **Colours:** Claude now runs from terracotta to soft clay. Every adapter
  declares its palette as a `theme` in `agents/`, and the sidecar and pond
  both read it.
- **Performance:** a pane in a hidden tab pauses its animations and most
  polling. Finished tool calls and subagent calls are freed, which stopped a
  leak of tens of MB in long sessions. Git is read without subprocesses when
  the folder hasn't changed.

### rex-crab-pond

- Agent crabs and their titles take their agent's gradient: Codex is now blue
  to indigo, not green, and its subagents periwinkle.
- A pond in a hidden tab stops drawing and checking programs, and a visible
  one skips frames where nothing moved. Rendering is about 4.6× faster.

### Agents

- agy's `lsof` lookup skips DNS, so it no longer stalls for up to half a
  second.
- The Pi extension also follows tree navigation, compactions and thinking
  level changes.

### rex-view removed

- The rex-view skill plugin is gone from the repository and the marketplace.
  Uninstall it with `claude plugin uninstall rex-view@rex-extensions`.
- The sidecar's Search Panel and Artifacts tab keep their viewer, now at
  `rex-sidecar/viewer`. The Search Panel picture is now
  `docs/search-panel.png`.

### Docs

- New pictures of the sidecar, the agent colours and the crab pond.
- The sidecar README has a new section on the log.

### Thanks

Thanks to Timofei Bogoliubov for the themes, the LOG, the 60 Hz turn box,
Code Mode support and the performance work (#8 to #11).

## v1.2.2 — 2026-11-22

- **rex-sidecar:** Pi and OpenCode panes get colours of their own, like Codex
  and agy. Pi runs from pink to orchid with blush subagents, OpenCode from
  slate to silver with misty subagents.
- **Docs:** the colours picture shows all four agents.

## v1.2.1 — 2026-11-22

Two fixes to v1.2.0, and new pictures.

- **rex-crab-pond:** running agy subagents get their light blue crabs. The
  adapter never marked them as running, so the pond left them out.
- **rex-sidecar:** a file Codex adds shows as `+` in the LOG box, like the
  other agents', instead of `•`.
- **Docs:** new pictures of the sidecar (with the LOG box), the Codex and agy
  colours, the crab pond with agy, Pi and OpenCode, and rex-resume with all
  five agents. The agy docs cover subagents, effort from the model ID and the
  new edit tools.

## v1.2.0 — 2026-11-22

Pi and OpenCode support, leaf as the viewer, agy at par with the other
agents, per-agent colours, a compact LOG box, no more resize flicker, and the
Tasks tab under its old name.

### Pi and OpenCode

- rex-sidecar, rex-crab-pond and rex-resume work with
  [Pi](https://github.com/badlogic/pi-mono) and [OpenCode](https://opencode.ai),
  through new adapters (`agents/pi.lua`, `agents/opencode.lua`) and sidecar
  parsers (`parsers/pi.lua`, `parsers/opencode.lua`).
- **Pi:** the sidecar shows prompts, replies, commands, edits (with Pi's own
  line numbers), new files, the model, thinking level, context and questions.
  pi-subagents runs show as lanes and crabs. A new Pi extension,
  `agents/pi-rex-status.ts`, records which session each `pi` writes, with its
  model's context window; link it into `~/.pi/agent/extensions/`. Without it,
  a pane's session is the folder's newest one.
- **OpenCode:** a pane's session is read, read only, from OpenCode's
  database, and copied to `~/.config/rex/state/opencode/` for the sidecar.
  Commands with their exit codes, edits and patches, new files, the model and
  its variant, the context against the model's window, questions and child
  sessions (subagents) show.
- rex-resume brings them back with `pi --session <file>` and
  `opencode --session <session>`, and both are on its default program list.
- Crabs: Pi is pink, OpenCode silver-grey, dressed by effort like Codex.
- GATE and PROCESSES stay empty for both, as neither records them.

### leaf

- [leaf](https://leaf.dipxsy.app) is now the viewer for the sidecar's diffs
  and for Rex View's documents and pictures, when it's installed:
  - **Changes:** a file's diff opens in leaf, in the same float. leaf gets the
    same diff as before, so every scope shows what it did.
  - **Artifacts, the Search Panel and rex-view:** Markdown, pictures, PDF,
    EPUB, HTML and Office files open in leaf. Code and text, and any file
    opened at a line, stay with `bat`.
  - Without leaf, the old viewers (delta, bat, glow) are used.
- When leaf is missing, the first diff or file a sidecar opens asks once, in
  the palette, whether to install it with Homebrew. **Don't ask again** is
  saved in `settings.json`, and the new **Rex View: Install leaf** action asks
  again.
- **rex-view 0.6.0:** when leaf is missing, `show` says so, and Claude asks you
  before installing it.

### Antigravity CLI (agy)

- The main box matches the other agents: effort (from the Gemini model ID),
  a readable model name (`gemini-4-neon-high` → Gemini 4 Neon), mode, branch,
  the conversation's title and compactions. The context window defaults to
  1M until the status line reports it.
- Subagents show as lanes and crabs (light blue), read from
  `conversation_summaries.db`. Workflow test runs and their errors count, and
  backgrounded commands no longer count as errors.
- Last Turn shows diffs from agy's `write_file` and `edit_file` as well as
  the older `write_to_file` and `replace_file_content`.
- Fixed a crash when a command failed without an exit code, such as a spawn
  error or a backgrounded command.

### rex-sidecar

- **Agent colours:** Codex panes get a blue to indigo gradient on the main
  and turn borders, title and effort bar, with periwinkle subagents. agy
  panes get Google's four colours, with light blue subagents. Claude keeps
  its coral and lavender.
- **LOG box:** times are `HH:MM`, shown once per minute. A one-column icon
  and a colour per kind replace the `who` column: prompts, writes, edits,
  deletes, workflows, subagents, advisor, errors and compactions. Paths are
  shortened to `parent/file`, and repeated events fold into one row with
  `×N`. Prompts never fold.
- **Resizing:** the sidecar draws each frame in one go (synchronized output),
  checks its size every 0.2s and redraws fully when the height changes too,
  so a pane resized in a background tab no longer comes back broken or
  flickers.
- **Tasks tab:** the Google tab is named **Tasks** again. A v1.1.0
  **Google Tasks** tab keeps its place and state.

### Skills

- **rex-sidecar-task-list 0.2.1:** the setup skill checks the **Tasks** tab
  by its new name, so it no longer reports it as hidden.

### Docs

- Install by cloning straight into Rex's config folder.
- Agent compatibility, troubleshooting and uninstall sections, and per-agent
  setup in one place with extension setup tables.

## v1.1.0 — 2026-11-22

Agy support, two task tabs with Reminders done properly, task editing and
deleting, a clock on the Info tab, and rewritten docs.

### rex-sidecar

- The Info tab's top line shows the date and time.

### Antigravity CLI (agy)

- rex-sidecar, rex-crab-pond and rex-resume work with `agy`, through a new
  adapter, `agents/agy.lua`, and a sidecar parser, `parsers/agy.lua`.
- A pane's conversation is the one whose lock file its `agy` process holds
  open (read with `lsof`), or else the folder's last conversation.
- The sidecar shows the model, context, prompts, replies, commands, tests,
  edits and open questions. GATE, PROCESSES and subagents stay empty, as agy
  doesn't log them.
- With the new `agents/agy-statusline.sh` as agy's status line, the sidecar
  also shows agy's effort, context window and usage quota (the 5h and weekly
  buckets), and the crab dresses by effort.
- The crab is Google blue.
- rex-resume brings agy back with `agy --conversation <conversation>`, and
  `agy` is on its default program list.

### rex-sidecar: two task tabs

The Tasks tab is now two tabs, **Google Tasks** and **Reminders**, which you
can show on their own or together. Their shared code lives in
`rex-sidecar/tasks-core.lua`.

- **Upgrading:** the first time the sidecar opens, the old Tasks tab's place
  and state move to the tab of the source it used. The `W` key, which chose
  the source, is gone.
- **Reminders** now does what Apple Reminders supports, and no more:
  - A, B and C are stored in the reminder's Priority field (High, Medium,
    Low), so Apple's apps show them too. The tab still shows A, B and C, and
    the same keys set them. A title that still starts with "A. " counts as
    before, and loses the prefix the next time you rate it.
  - `l` chooses which lists show, and the default list for new tasks.
  - `m` moves a task to another list. EventKit can't change a reminder's
    list, so the move copies the reminder and deletes the original.
    Attachments, tags and subtasks made in Apple's app don't come along.
  - Steps and "split it into steps" warnings are gone, as Reminders has no
    subtasks for other programs.
- **Both task tabs:**
  - `E` edits a task: its rating, title and estimate, and its date when you
    type one last.
  - `x` on a task done today marks it not done again. Done tasks can now be
    selected.
  - `D` deletes a task, with its steps, after you confirm with `y`. Both
    providers have a new `delete` command.
  - A task's name can't be left empty when adding or editing it.
  - A blank line now separates the view switcher from the first box.

### Task actions and skill

- The task actions use whichever task tabs are shown, and take
  `provider=google|apple`. `tasks_list` names each list's provider and each
  task's rating.
- The skill plugin is renamed **rex-sidecar-task-list** (0.2.0), with the
  skills `rex-sidecar-task-list` and `rex-sidecar-tasks-setup`. Uninstall
  `sidecar-task-list` and install the new one; see the README's Update
  section.

### Docs

- The repository is now called "Rex extensions and agent skills".
- Every README is rewritten to be easier to read.
- New pictures: the sidecar with the Reminders tab, the Reminders tab's
  views and list picker, and a diagram of what rex-resume brings back.

## v1.0.1 — 2026-11-22

### rex-resume

- Codex comes back in its conversation, with `codex resume <thread>` in the
  thread's directory, found through the Codex adapter in `agents/`.
- `codex` is on the default program list. Leave it out of `programs` to have
  Codex panes come back as shells.

### Docs

- Every extension and plugin README opens with what it does for you, what
  you get, and a quick way to try it.

## v1.0.0 — 2026-11-22

The first numbered release. It covers everything since the repository
started, on 2026-10-31.

### Renamed

The extensions now start with `rex-`:

| Was | Is now |
| --- | --- |
| cc-sidecar (earlier cc-pane, then changes-pane) | rex-sidecar |
| cc-crab-pond (earlier crab-pond) | rex-crab-pond |
| cc-resume (earlier session-keeper) | rex-resume |

To upgrade, change the `require` lines in `~/.config/rex/init.lua` to the new
names, then run
`pkill -f 'extensions/.*/watcher\.lua'; rex config reload`. Settings files
move with their folders. The sidecar's and crabs' Rex actions are renamed the
same way: `cc_sidecar_view` is now `rex_sidecar_view`. Update any key
bindings you made to them.

### Codex support

- rex-sidecar and rex-crab-pond work with Codex as well as Claude Code,
  through the agent adapters in `agents/`.
- The sidecar reads a Codex thread from Codex's state database and rollout.
  A Codex pane gets every tab, except what Codex doesn't record: no GATE
  box, no PROCESSES box, and OPEN lists only the questions at the end of its
  last reply.
- In the pond, a Codex is a green crab, named after its thread and dressed by
  its reasoning effort.
- See [agents/README.md](agents/README.md) for how a pane's Codex thread is
  found and how to add another agent.

### rex-sidecar

A pane beside each Claude Code or Codex pane, with four tabs:

- **Changes**: the files changed in the last turn, the uncommitted work, or
  the branch or its open pull request, as a list or a folder tree. A click
  opens the diff in a float, highlighted by delta or bat.
- **Info**: a dashboard of boxes styled after
  [Flightdeck](https://github.com/scasella/claude-flightdeck):
  - the model, context, limits and request count;
  - permission checks (GATE) as dotted cells;
  - subagents as lanes on one time axis, newest first;
  - the shells and monitors running now (PROCESSES);
  - open questions;
  - a receipt for the turn, with tests and failed commands;
  - a session log.
- **Artifacts**: the documents, PRs (by title), Jira issues (by title), links
  and files the agent's replies mention, the newest 10 per section. The fzf
  Search Panel lists all of them.
- **Tasks**: the day's work from Google Tasks or Apple Reminders, hidden
  until you show it.

The tabs are plugins: you can show, hide and reorder them, and add your own.
Heavy work runs in the background, so keys and clicks don't wait. Very long
transcript lines are read without stalling.

### rex-crab-pond

- One animated crab per agent, subagent, background job and program in the
  tab, along the bottom of the tab.
- A build crab's hard hat takes its program's brand colour.

### rex-resume

- Brings Claude Code conversations back after the Rex server restarts.
- Also brings back other programs, set in `settings.json`, in one of three
  modes:
  - `allow_name`: listed programs, by name only;
  - `allow_full`: listed programs, with their arguments (the default);
  - `any_full`: any program, with its arguments.

### Skills

- **rex-view 0.5.1**: Claude shows images, Markdown and source code in a
  floating pane. Markdown uses the full width, and short files are drawn from
  the top.
- **sidecar-task-list 0.1.0**: Claude adds the work you start to the sidecar's
  Tasks tab and reports it done for you to confirm.

### Fixes

- Claude and Codex are found whatever the case of the command that started
  them, such as `Claude`.
- Team agents that never get a finished flag show as idle after 5 minutes,
  not as running.

### Thanks

Thanks to Timofei Bogoliubov (Tasks tab, tab plugins, long transcript lines,
brand-coloured hard hats) and Tal Friedman (agent adapters and Codex
support).
