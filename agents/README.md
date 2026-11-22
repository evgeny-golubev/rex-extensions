# Agent adapters

**One sidecar, one pond, any coding agent.** rex-sidecar and rex-crab-pond ask
this folder which agent a pane runs and where its session is, so they never
name an agent themselves. rex-resume uses it to find a Codex pane's thread.
Two adapters ship today, Claude Code and Codex. Adding another takes
[one adapter and one parser](#adding-an-agent).

## What ships

| Adapter | Finds a pane's agent by | Finds its session in | Reads its transcript from |
| --- | --- | --- | --- |
| `claude.lua` | Program name `claude`, in any case | `~/.claude/sessions/<pid>.json` (or under `$CLAUDE_CONFIG_DIR`), plus the saved status line input | `projects/<project>/<session>.jsonl` |
| `codex.lua` | Program name `codex`, in any case | The `threads` table of Codex's state database, `~/.codex/state_<n>.sqlite` (or under `$CODEX_HOME`) | The thread's `rollout_path` |

An agent counts whether it runs in the pane's foreground or as the parent of
the foreground command, so `claude` running `git` still counts.

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

A session always has `id`, `pid`, `transcript` (a JSONL path) and `cwd`. When
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
2. Add it to `A.list` in `init.lua`.
3. Add a parser with the same ID in `rex-sidecar/parsers/`, and list it in
   `panel.lua`.

## Tests

```sh
rex do ~/.config/rex/extensions/agents/test.lua
```

The tests fake `sqlite3` and `ps`, and use a throwaway folder for Claude
Code's files. They don't read the real `~/.claude` or `~/.codex`.
