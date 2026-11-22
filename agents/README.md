# Agent adapters

**One sidecar, one pond, any coding agent.** rex-sidecar and rex-crab-pond ask
this folder which agent a pane runs and where its session is, so they never
name an agent themselves. rex-resume uses it to find a Codex or agy pane's
conversation. Three adapters ship today: Claude Code, Codex and the
Antigravity CLI (`agy`). Adding another takes
[one adapter and one parser](#adding-an-agent).

**On this page:** [What ships](#what-ships) · [Claude Code](#claude-code) ·
[Codex](#codex) · [agy](#antigravity-cli-agy) ·
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

An agent counts whether it runs in the pane's foreground or as the parent of
the foreground command, so `claude` running `git` still counts.

## Claude Code

The adapter checks `$CLAUDE_CONFIG_DIR` first, then `~/.claude`. The running
process's session file supplies the conversation ID and working directory;
the transcript supplies replies, edits and subagents. A saved status line
adds model, effort, context capacity and usage limits.

The status line is optional for session discovery. To enable its extra
fields, follow the [status line setup](../rex-crab-pond/README.md#claude-code-status-line).
Save its JSON under the same config directory as the session files.

rex-resume has its own Claude session lookup and currently only reads
`~/.claude/sessions/`; the adapter's custom-directory support does not extend
to Claude restoration.

## Codex

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

An edit is any tool call whose name has write, replace, edit or create in it
and whose arguments name a file (`TargetFile`, `AbsolutePath`, `FilePath`,
`File` or `Path`). Its lines come from `CodeContent`, or from
`TargetContent` and `ReplacementContent`. agy doesn't log line numbers, so
Last Turn's diffs show the changed lines without their place in the file.

**Model, effort, context and usage.** agy hands its status line command a
JSON summary: the model, its effort, the context window and the usage quota.
`agy-statusline.sh` saves it as `state/statusline/<conversation>.json`, and
the adapter reads it. The quota comes in buckets of the fraction left and a
reset time: `gemini-5h` and `gemini-weekly` for Gemini models, `3p-5h` and
`3p-weekly` for others. They show as the 5h and 7d bars, like Claude's.
Without the script, the model comes from the transcript and there are no
usage bars. See the [root install guide](../README.md#install) for the setting.

**What an agy pane doesn't show:** GATE (no permission decisions are logged),
PROCESSES and background job crabs, and subagents. `ask_question` shows in
OPEN until you answer.

rex-resume brings an agy pane back with `agy --conversation <conversation>`.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| An agent is recognised but its session is empty | Wait for Claude to write its session file, or send the first prompt in Codex or agy. Process recognition alone does not identify a conversation. |
| Codex shows the wrong thread | Give threads in the same folder distinct names. Check that `$CODEX_HOME` points to the intended profile and that `sqlite3` is available. |
| agy shows the wrong conversation | The folder fallback cannot distinguish panes in the same folder. Check that `lsof` can read the agy process's open presence lock. |
| Model or usage fields are missing | Check the Claude or agy status line setup. Only fields present in the saved JSON or transcript can be shown. |

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
