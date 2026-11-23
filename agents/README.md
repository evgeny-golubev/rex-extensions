# Agent adapters

**One sidecar, one pond, any coding agent.** rex-sidecar and rex-crab-pond ask
this folder which agent a pane runs and where its session is, so they never
name an agent themselves. rex-resume uses it to find a Codex, agy, Pi or
OpenCode pane's conversation. Five adapters ship today: Claude Code, Codex, the
Antigravity CLI (`agy`), Pi and OpenCode. Adding another takes
[one adapter and one parser](#adding-an-agent).

**On this page:** [What ships](#what-ships) ·
[Setup at a glance](#setup-at-a-glance) · [Claude Code](#claude-code) ·
[Codex](#codex) · [agy](#antigravity-cli-agy) · [Pi](#pi) · [OpenCode](#opencode) ·
[Troubleshooting](#troubleshooting) · [Interface](#interface) ·
[Adding an agent](#adding-an-agent) · [Tests](#tests)

This is a shared library loaded by the extensions, with no separate install
or `require` line in your Rex config. Keep `agents/` beside the extension
folders when installing. See the [repository install guide](../README.md#install).

## What ships

| Adapter | Finds a pane's agent by | Finds its session in | Reads its transcript from |
| --- | --- | --- | --- |
| `claude.lua` | Program name `claude`, in any case | `~/.claude/sessions/<pid>.json` (or under `$CLAUDE_CONFIG_DIR`), plus the saved status line input | `projects/<project>/<session>.jsonl` |
| `codex.lua` | Program name `codex`, in any case | The `threads` table of Codex's state database, `~/.codex/state_<n>.sqlite` (or under `$CODEX_HOME`) | The thread's `rollout_path` |
| `agy.lua` | Program name `agy`, in any case | The conversation lock the process holds open in `~/.gemini/antigravity-cli/presence/`, else the folder's last conversation | `brain/<conversation>/.system_generated/logs/transcript_full.jsonl` |
| `pi.lua` | Program name `pi`, in any case | What `pi-rex-status.ts` records in `~/.pi/agent/state/rex/<pid>.json`, else the folder's newest session since `pi` started | `~/.pi/agent/sessions/--<folder>--/<time>_<id>.jsonl` |
| `opencode.lua` | Program name `opencode` or `.opencode` | The `session_v2` table of `~/.local/share/opencode/opencode.db`: the folder's newest top-level session since `opencode` started | A copy of its messages in `~/.config/rex/state/opencode/<session>.jsonl` |

An agent counts whether it runs in the pane's foreground or as the parent of
the foreground command, so `claude` running `git` still counts.

## Setup at a glance

All five agents work out of the box once the extensions are installed. Optional
per-agent setup unlocks extra fields (context usage, limits, effort outfits or
exact session tracking):

| Agent | Required setup | Optional setup | What optional setup adds |
| --- | --- | --- | --- |
| [Claude Code](#claude-code) | None | Save status line input (`jq`); set `"diffSidebarOpen": false` for sidecar | Context %, 5h/7d usage limits, pond outfits and monitor descriptions; hides Claude's duplicate diff panel |
| [Codex](#codex) | None (uses macOS `sqlite3`) | None | — |
| [Antigravity CLI (`agy`)](#antigravity-cli-agy) | None (uses macOS `lsof` and `sqlite3`) | Configure `agy-statusline.sh` (`jq`) | 5h/7d usage quota bars and permission mode; context % for non-Gemini models and effort for models without an effort suffix |
| [Pi](#pi) | None | Link `pi-rex-status.ts` into Pi's extensions | Exact session matching (including `--session` / `/resume`), context % and thinking level |
| [OpenCode](#opencode) | None (OpenCode 2.x + macOS `sqlite3`) | None | — |

## Claude Code

### Setup

Session discovery and transcripts need no setup. For model, effort, context
capacity, 5h/7d usage limits, pond outfits and monitor descriptions, save
Claude Code's status line JSON input (`jq` is required: `brew install jq`):

If you already have a status line script (`"statusLine"` in
`~/.claude/settings.json`), add the save lines after it reads stdin into
`$input` (read stdin only once):

```bash
# Read JSON input from stdin
input=$(cat)

# Save the input for rex-sidecar and rex-crab-pond
sid=$(echo "$input" | jq -r '.session_id // empty')
[ -n "$sid" ] && mkdir -p ~/.claude/state/statusline && printf '%s' "$input" > ~/.claude/state/statusline/"$sid".json
```

If you have no status line script yet, save this as
`~/.claude/statusline-command.sh`:

```bash
#!/bin/bash
input=$(cat)
sid=$(echo "$input" | jq -r '.session_id // empty')
[ -n "$sid" ] && mkdir -p ~/.claude/state/statusline && printf '%s' "$input" > ~/.claude/state/statusline/"$sid".json
echo "$input" | jq -r '.model.display_name'
```

Then merge this into `~/.claude/settings.json`:

```json
{
  "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh" }
}
```

If you use `$CLAUDE_CONFIG_DIR`, use that directory in place of `~/.claude` for
the settings, script and saved status line files. Claude Code runs the command
as the session updates, so a running session picks it up after its next reply.
Delete `~/.claude/state/statusline/` any time to clear saved files.

If you use `rex-sidecar`, also disable Claude Code's built-in diff panel so you
don't get two sidebars: set `"diffSidebarOpen": false` in `~/.claude.json`.

### How it works

The adapter checks `$CLAUDE_CONFIG_DIR` first, then `~/.claude`. The running
process's session file supplies the conversation ID and working directory;
the transcript supplies replies, edits and subagents. A saved status line
adds model, effort, context capacity and usage limits.

rex-resume has its own Claude session lookup and currently only reads
`~/.claude/sessions/`; the adapter's custom-directory support does not extend
to Claude restoration.

## Codex

### Setup

No extra setup is needed. Codex sessions are read from its local SQLite state
database using the `sqlite3` that comes with macOS (under `$CODEX_HOME` if set,
otherwise `~/.codex`).

### How a pane's thread is found

A Codex window doesn't record which thread it shows. Its threads run in a
shared app-server, so no file names the thread either. So the adapter looks it
up in Codex's state database, in this order:

1. **The pane's title.** Codex sets it to `<thread name> | <folder>`, with a
   braille spinner in front while it works. A thread with that name in the
   pane's folder wins, then one anywhere (as after `/cd`). Codex cuts a long
   name with `...`. A cut name only matches in the pane's folder.
2. **The thread ID in `codex resume <id>`,** read from the command line in
   `ps`.
3. **The one thread in the pane's folder that started after the program
   did.** If there are two, as when two Codex panes start in one folder,
   neither is picked until Codex names the thread and step 1 finds it.

Only interactive threads count. Archived threads, subagent and reviewer
threads, and `codex exec` runs are left out.

rex-resume saves the thread found here and brings the pane back with
`codex resume <thread>`.

### Subagents and limits

- A subagent counts as finished once the parent's rollout says it completed
  or was stopped. It runs again if it gets more work.
- Usage limits belong to the account, so they're read from the end of the
  rollout that changed last, whichever thread that is. An idle pane's own
  rollout would have old ones.

### What a Codex pane doesn't show

Codex doesn't record some things, so the sidecar leaves them out for a Codex
pane:

- **GATE:** the rollout has no approval decisions.
- **PROCESSES, and background job crabs:** Codex runs commands under its
  app-server, not in the pane's process, so they can't be told apart by pane.
- **OPEN** lists only the questions at the end of Codex's last reply. The
  rollout has no task list or pending-question tool.

### Known limits

- Two Codex panes in the same folder, showing threads with the same name, can
  be mixed up. Renaming one thread tells them apart.
- Rex reports only a program's name. So any `codex` command in a pane, such as
  `codex login`, counts as a Codex until it exits.

## Antigravity CLI (agy)

### Setup

Conversation discovery needs no setup (it uses the `lsof` that comes with
macOS, and `sqlite3` for titles and subagents). For the usage quota bars, the
permission mode, the exact context window (Gemini models otherwise count as
1M, others show no context %) and the effort of models without an effort
suffix, configure the bundled status line script in
`~/.gemini/antigravity-cli/settings.json`, then restart `agy`:

```json
"statusLine": { "type": "command", "command": "/Users/you/.config/rex/extensions/agents/agy-statusline.sh" }
```

Use the full path to your home folder in place of `/Users/you` (don't use `~`).
The script needs `jq` (`brew install jq`), saves the JSON to
`~/.gemini/antigravity-cli/state/statusline/<conversation>.json`, and displays
the model name and context percentage.

### How it works

agy keeps each conversation under `~/.gemini/antigravity-cli/`.

**Finding a pane's conversation.** While agy has a conversation open, its
process holds `presence/<conversation>.lock` open. The adapter reads the
process's open files with `lsof` (file paths only, not its command line) and
takes the conversation from that lock. If that fails, it takes the folder's
last conversation from `cache/last_conversations.json`. That fallback can't
tell two agy panes in one folder apart.

**What the sidecar reads.** The transcript is one JSON step per line:

- `USER_INPUT`: your prompt, inside `<USER_REQUEST>`;
- `PLANNER_RESPONSE`: a model step with the model, token counts, a reply and
  tool calls;
- `GENERIC`: each tool's result, in the order of the calls. A command's result
  ends with "exited with code N".

- `CHECKPOINT`: a context compaction, counted next to the context (⟲).

An edit is any tool call whose name has write, replace, edit or create in it
and whose arguments name a file (`TargetFile`, `AbsolutePath`, `FilePath`,
`File` or `Path`). Its lines come from `CodeContent` or `Content` (agy's
`write_file`), or from `TargetContent` and `ReplacementContent`, or `Target`
and `Replacement` (agy's `edit_file`). agy doesn't log line numbers, so Last
Turn's diffs show the changed lines without their place in the file.

`run_workflow` runs count as tests when their script is a test command, and
a tool still running in the background (`RUNNING`) isn't an error.

**Title and subagents.** The conversation's title and its subagents come from
`conversation_summaries.db`, read with the `sqlite3` that comes with macOS
(`-readonly`). A subagent is a conversation whose parent is the pane's
conversation; it shows as a lane in AGENTS, and as a light blue crab while it
runs. `invoke_subagent` calls give the lanes their roles.

**Model, effort, context and usage.** agy hands its status line command a
JSON summary: the model, its effort, the context window and the usage quota.
`agy-statusline.sh` saves it as `state/statusline/<conversation>.json`, and
the adapter reads it. The quota comes in buckets of the fraction left and a
reset time: `gemini-5h` and `gemini-weekly` for Gemini models, `3p-5h` and
`3p-weekly` for others. They show as the 5h and 7d bars, like Claude's.
Without the script, the model comes from the transcript, its effort from the
model ID's suffix (`gemini-4-neon-high` is high), the context window is 1M for
Gemini models, and there are no usage bars or permission mode. Model names are shown readable:
`gemini-4-neon-high` as Gemini 4 Neon.

**What an agy pane doesn't show:** GATE (no permission decisions are logged),
PROCESSES and background job crabs. `ask_question` shows in OPEN until you
answer.

rex-resume brings an agy pane back with `agy --conversation <conversation>`.

## Pi

### Setup

Basic discovery needs no setup, but linking the bundled Pi extension is
recommended so `rex-sidecar`, `rex-crab-pond` and `rex-resume` always know each
pane's exact session (including `--session` and `/resume`), context window
percentage and thinking level:

```sh
mkdir -p ~/.pi/agent/extensions
ln -s ~/.config/rex/extensions/agents/pi-rex-status.ts ~/.pi/agent/extensions/rex-status.ts
```

Then restart Pi. If you set `PI_CODING_AGENT_DIR`, link into
`$PI_CODING_AGENT_DIR/extensions/` instead.

### How it works

[Pi](https://github.com/badlogic/pi-mono) keeps each session as a JSONL file
in `~/.pi/agent/sessions/`, in a folder named after the directory with `/` as
`-` (`--Users-me-app--`). Set `PI_CODING_AGENT_DIR` and the adapter looks
there instead of `~/.pi/agent`.

**Finding a pane's session.** Pi names its process `pi`, so its command line
(`--session`, `--continue`) can't be read, and it doesn't keep the session
file open. So:

1. With the Pi extension installed, each `pi` writes
   `state/rex/<pid>.json`: its session file, model, context window, thinking
   level and whether it's working. It updates on start, `/new`, `/resume`,
   `/fork`, a model change and every turn, and removes the file when Pi exits.
2. Without it, the session is the folder's newest file that changed since
   this `pi` started. A `pi` that hasn't saved a message yet has none, and a
   session file kept elsewhere with `--session` isn't found.

**What the sidecar reads.** `message` records hold the conversation: user
prompts, assistant messages with text, thinking and tool calls, and a
`toolResult` for each call. `bash` calls count as commands, failed when the
result is an error. `edit` changes come from the diff Pi saves with the
result, with real line numbers; `write` counts as a new file. Model and
thinking-level changes, and the token counts of each reply, fill the model,
effort and context. A question from an ask-user tool shows in OPEN until you
answer.

**Subagents.** The pi-subagents package runs each step as a Pi session of its
own, under `<session>/<run>/run-<n>/`. Each one is a lane and a crab,
described by the start of its task. It counts as finished once its last reply
ended without a tool call, and as running while it changed in the last 10
minutes.

**What a Pi pane doesn't show:** GATE (Pi logs no permission decisions),
PROCESSES and background job crabs. Without the extension, the context has
no percentage, as the transcript doesn't record the model's window.

rex-resume brings a Pi pane back with `pi --session <file>`.

## OpenCode

### Setup

No extra setup is needed. Requires OpenCode 2.x; sessions are read with the
`sqlite3` that comes with macOS (from `$OPENCODE_DB`, `$XDG_DATA_HOME`, or
`~/.local/share/opencode/opencode.db`).

### How it works

[OpenCode](https://opencode.ai) 2.x keeps its sessions in a SQLite
database, `~/.local/share/opencode/opencode.db` (or `$OPENCODE_DB`, or under
`$XDG_DATA_HOME`), which its background service writes. The adapter only
reads it, with `sqlite3 -readonly`. The adapter follows the database layout of
OpenCode 2.3.2; 1.x databases aren't read.

**Finding a pane's session.** An OpenCode TUI is a client of that service, so
nothing links a process to a session. The adapter takes the session named
with `--session` or `-s` on the command line, or else the newest top-level,
unarchived session in the pane's folder that changed since this `opencode`
started. Two OpenCode panes in one folder can't be told apart.

**What the sidecar reads.** The sidecar reads transcripts from files, so the
adapter copies the session to `~/.config/rex/state/opencode/<session>.jsonl`:
one line per message once it's final, with its parts, as the database holds
them, and a line for a question while it waits. Only new messages are added,
under a lock, so the sidecar and the pond don't copy one twice.

- `shell` calls count as commands, failed when their exit code isn't 0; a
  `!` command you type counts too.
- `edit` and `patch` changes come from the unified diffs OpenCode records;
  `write` counts as a new file.
- The model and its variant, which the crab dresses by, come from the
  session. The context window comes from OpenCode's cached models.dev list.
- A `question` shows in OPEN until you answer.
- Subagents are child sessions. A child counts as finished once it went idle
  after its last busy spell.

**What an OpenCode pane doesn't show:** GATE (permission requests live only in
OpenCode's memory), PROCESSES and background job crabs. Usage limits aren't
recorded.

rex-resume brings an OpenCode pane back with `opencode --session <session>`.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| An agent is recognised but its session is empty | Wait for Claude to write its session file, or send the first prompt in Codex, agy, Pi or OpenCode. Process recognition alone does not identify a conversation. |
| Codex shows the wrong thread | Give threads in the same folder distinct names. Check that `$CODEX_HOME` points to the intended profile and that `sqlite3` is available. |
| agy shows the wrong conversation | The folder fallback cannot distinguish panes in the same folder. Check that `lsof` can read the agy process's open presence lock. |
| A Pi pane shows the wrong session, or none | Install the Pi extension and restart Pi. Without it, only the folder's newest session since `pi` started is found. |
| An OpenCode pane shows no session | Send the first prompt. Check that `~/.local/share/opencode/opencode.db` exists and `sqlite3 -readonly` can open it. |
| Model or usage fields are missing | Check the Claude or agy status line setup, or the Pi extension. Only fields present in the saved JSON or transcript can be shown. |

The adapters follow each CLI's local storage format. After a CLI update,
check its session files and transcript format if discovery or parsing stops
working. For watcher logs, see the [main troubleshooting guide](../README.md#troubleshooting).

## Interface

`init.lua` loads the adapters and finds the one a pane runs:

```lua
local agents = dofile(repo .. "agents/init.lua")
local adapter, sess = agents.session(process, session_id, block_id)
```

`process` is the result of the terminal's `process` block call.

Every adapter has these fields:

| Field | What it is |
| --- | --- |
| `id`, `name` | `"codex"`, `"Codex"` |
| `theme` | Hex palette `{ accent, agent, clock, gradient }` shared by `rex-sidecar` and `rex-crab-pond` |
| `matches(p)` | Whether a process from `process` is this agent |
| `session(pane)` | The pane's session, or nil. `pane` has `pid`, `cwd`, `session_id` and `block_id` |
| `subagents(sess, now)` | The session's subagents, oldest first |

A session has `id`, `pid` and `cwd`; `transcript` is a JSONL path when found
and can be nil while the agent is starting. When
known, it also has `name`, `started` (seconds since 1970, when the program
started), `working`, `model`, `model_label`, `effort`, and
`status = { window = context tokens, limits = { { label, used, resets_at } } }`.

A subagent has `id`, `transcript`, `type`, `description`, `finished` and
`running`. When known, it also has `model`, `started` and `updated`.

The sidecar reads each agent's transcript with a parser of the same ID in
[`rex-sidecar/parsers/`](../rex-sidecar/parsers). A parser writes the panel's
shared state through its helpers (`add_prompt`, `reply`, `add_hunks`,
`command_ran`, `log`, `gate_check`, and more). It has `record`, `skip`,
`agent_record` and `turns`.

## Adding an agent

1. Add an adapter file here, with the fields above.
2. Load it in `init.lua`, add it to `A.list`, and expose it through `A.by_id`.
3. Add a parser with the same ID in `rex-sidecar/parsers/`, and list it in
   `panel.lua`.

Use `claude.lua` and `codex.lua`, and their matching parsers, as examples of
two storage formats implementing the same interface. Add adapter cases to
`test.lua` and parsing cases to `../rex-sidecar/test.lua`. An adapter and
parser enable sidecar and pond integration; conversation restoration also
needs an entry in rex-resume's `resumable` table.

## Tests

```sh
rex do ~/.config/rex/extensions/agents/test.lua
```

The tests fake `sqlite3` and `ps`, and use a throwaway folder for Claude
Code's files. They don't read the real `~/.claude` or `~/.codex`.
