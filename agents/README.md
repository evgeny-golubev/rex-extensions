# Agent adapters

cc-sidecar and cc-crab-pond work with more than one coding agent. This folder
holds what differs between agents, behind one interface, so the extensions
themselves don't name an agent. Two adapters ship: Claude Code and Codex.

| Adapter | Recognised by | Session from | Transcript |
| --- | --- | --- | --- |
| `claude.lua` | Program name `claude` | `~/.claude/sessions/<pid>.json`, or under `$CLAUDE_CONFIG_DIR`, and the saved status line input | `projects/<project>/<session>.jsonl` |
| `codex.lua` | Program name `codex` | The `threads` table of Codex's state database, `~/.codex/state_<n>.sqlite`, or under `$CODEX_HOME` | The thread's `rollout_path` |

Both are found in the foreground of a pane or as the parent of its foreground
command.

## Interface

`init.lua` loads the adapters and finds the one a pane runs:

```lua
local agents = dofile(repo .. "agents/init.lua")
local adapter, sess = agents.session(process, session_id, block_id)
```

`process` is the result of the terminal's `process` block call. Every adapter
has:

| Field | What it is |
| --- | --- |
| `id`, `name` | `"codex"`, `"Codex"` |
| `matches(p)` | Whether a process from `process` is this agent |
| `session(pane)` | The pane's session, or nil. `pane` has `pid`, `cwd`, `session_id` and `block_id` |
| `subagents(sess, now)` | The session's subagents, oldest first |

A session has `id`, `pid`, `transcript` (a JSONL path) and `cwd`, and when
known `name`, `started` (seconds since 1970, the program's start),
`working`, `model`, `model_label`, `effort` and
`status = { window = context tokens, limits = { { label, used, resets_at } } }`.
A subagent has `id`, `transcript`, `type`, `description`, `finished`,
`running`, and when known `model`, `started` and `updated`.

The sidecar reads each agent's transcript with a parser of the same ID in
[`cc-sidecar/parsers/`](../cc-sidecar/parsers). A parser writes the panel's
shared state through its helpers (`add_prompt`, `reply`, `add_hunks`,
`command_ran`, `log`, `gate_check`, …) and has `record`, `skip`,
`agent_record` and `turns`.

To add an agent, add an adapter here and to `A.list` in `init.lua`, and a
parser with the same ID in `cc-sidecar/parsers/`, listed in `panel.lua`.

## Codex

A Codex TUI doesn't record which thread it shows, and its threads run in a
shared app-server, so its process has no file that names the thread. The
adapter finds a pane's thread in Codex's state database, in this order:

1. The pane's title, which Codex sets to `<thread name> | <folder>`, with a
   braille spinner before it while it works. A thread of that name in the
   pane's directory comes first, then one anywhere, as after `/cd`. A long
   name is cut short with `...`; its start matches only in the pane's
   directory.
2. The thread ID in `codex resume <id>`, from `ps`.
3. The one thread in the pane's directory that started after the program
   did. With two, as when two Codex panes start in one folder, none is
   picked until Codex names the thread and step 1 finds it.

Only interactive threads count: subagent, reviewer and `codex exec` threads
are left out. A subagent counts as finished once the parent's rollout says it
completed or was stopped, and runs again if it gets more work.
Usage limits are the account's, so they're read from the end of the rollout
that changed last, whichever thread it is; an idle pane's own rollout has old
ones.

What Codex doesn't record, the sidecar leaves out for a Codex pane:

- **Gate**: the rollout has no approval decisions.
- **Processes** and background task crabs: Codex runs commands under its
  app-server, not the TUI, so they can't be told apart by pane.
- **Open** lists only the questions at the end of Codex's last reply: the
  rollout has no task list or pending question tool.

Two Codex panes in the same directory showing threads with the same name can
be confused; renaming one tells them apart. Rex reports only a program's
name, so any `codex` command in a pane, such as `codex login`, counts as a
Codex until it exits.

## Tests

```sh
rex do ~/.config/rex/extensions/agents/test.lua
```

The tests fake `sqlite3` and `ps` and use a throwaway folder for Claude Code's
files; they don't read the real `~/.claude` or `~/.codex`.
