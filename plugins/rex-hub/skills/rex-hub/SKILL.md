---
name: rex-hub
description: Delegates tasks to another coding agent (claude, codex, agy, pi, or opencode) inside a minimized Rex floating pane in the current tab instead of running a blind shell command. Use this whenever the user asks you to run, consult, or delegate work to another agent CLI (for example, asking Claude to run Codex, or asking agy to run Claude). Not for your own subagents, which run through your own harness. Supports both oneshot tasks (auto-closes on completion) and interactive multi-turn sessions where you can talk to the delegated agent and decide when to close it.
---

# Rex Hub — Delegating to Other Coding Agents

When the user asks you to run another coding agent (`claude`, `codex`, `agy`, `pi`, or `opencode`), **do not** run it directly as a plain shell command (such as `codex exec ...` or `claude -p ...`). Always launch it through **Rex Hub** (`rex do hub_*`) so it runs in a minimized floating pane inside the current tab, appears in the sidecar's **Info → HUB** box, and lets the user expand, watch, approve, or steer it at any time.

## Not for your own subagents

Rex Hub is only for running a **separate agent CLI**. Your own subagents must run through your own harness, never through Hub: Claude Code's Agent tool, Codex's subagents, agy's or Pi's own delegation. The same goes for "use a subagent", "in another agent" or "in parallel" when the user names no other CLI: that is your own subagent. Use Hub only when the user names a CLI to run (for example "ask codex", "run agy") or asks for Rex Hub by name.

## Choosing the mode

Decide the mode based on the task:

- **`mode=oneshot`** (default) — Use for self-contained, single-turn tasks (e.g., code review, answering a question, running a focused fix). By default it waits up to 25 seconds (`wait=true`) and returns the output if the agent ended by then; otherwise it returns `status: running` with the run `id` for you to poll. The floating pane closes when the agent ends.
- **`mode=interactive`** — Use for longer, exploratory, or back-and-forth sessions where you (or the user) may need multiple turns of communication. It returns immediately (`wait=false`) with a run `id` and **stays open** until you call `hub_stop`.

## Commands

Run these via Bash / your shell tool. Arguments are `key=value` pairs; quote values with spaces.

### 1. Start a delegated agent (`hub_run`)

One-shot that waits and returns the output:

```sh
rex do hub_run agent=codex task="Review auth.lua for race conditions"
```

Rex ends any `rex do` action after 30 seconds, so `hub_run` waits at most 25 seconds. If the agent hasn't finished by then, the result has `"status": "running"`, the run `id` and a `note`: poll `hub_status` with that `id` as below. The agent keeps running either way.

For work you know will take a while, or to fan out several agents in parallel, start them with `wait=false` and check back:

```sh
rex do hub_run agent=codex task="Review auth.lua" wait=false
rex do hub_run agent=agy task="Check docs for stale links" wait=false
rex do hub_status id=RUN_ID
rex do hub_read id=RUN_ID
```

Poll `hub_status` every 15–30 seconds until `status` is no longer `running`, then `hub_read` the output.

Interactive multi-turn session (starts minimized, stays open):

```sh
rex do hub_run agent=claude mode=interactive task="Investigate why test_sync fails intermittently"
```

Optional arguments for `hub_run`:
- `cwd=/path/to/dir` — working directory (defaults to the current pane's directory)
- `model=...` — model override for the target CLI (`opencode` takes none in interactive mode)
- `wait=true` or `wait=false` — wait for the agent to end (default: `true` for oneshot, `false` for interactive)
- `timeout=600` — how long a oneshot run may take, in seconds (default `600`); then it is ended with status `timeout`. Interactive runs have no limit

### 2. Talk to an interactive Hub agent (`hub_send` & `hub_read`)

An interactive agent needs a few seconds to start, and each reply takes a while. Read its screen, and check it again until the reply is complete before acting on it:

```sh
rex do hub_read id=RUN_ID
rex do hub_read id=RUN_ID lines=200
```

`lines` sets how many of the last screen lines come back (default `120`).

Send a follow-up message (it is typed into the agent and submitted with Enter):

```sh
rex do hub_send id=RUN_ID message="Focus only on the parser tests and show the diff"
```

Check status (`running`, `done`, `failed`, `stopped`, `timeout`) and float state (`minimized`, `normal`, `closed`), for one run or for every run in this Rex session:

```sh
rex do hub_status id=RUN_ID
rex do hub_status
```

### 3. Show or hide the float (`hub_toggle`)

```sh
rex do hub_toggle id=RUN_ID open=true
rex do hub_toggle id=RUN_ID
```

`open=true` shows and focuses the float; without it, the float is shown if minimized and minimized if shown. Use it when the user wants to watch or answer the agent.

### 4. Close an interactive Hub agent (`hub_stop`)

For `mode=interactive`, **you decide when the session is finished**. Once you have the answer or the work is complete, close the floating pane cleanly:

```sh
rex do hub_stop id=RUN_ID
```

Do not leave finished interactive Hub agents open unless the user asks to keep them open.

### 5. User visibility & control

- When a run returns before it ends (`wait=false`, `mode=interactive`, or `status: running` after the 25-second wait), tell the user the delegated agent and run ID in one short line (e.g., *"Started `codex` via Rex Hub (`codex-...`) in a minimized float — click it in Info → HUB to watch or steer."*).
- If `hub_run` fails because `hub_run` is not registered, tell the user that `require("extensions.rex-hub")` needs to be enabled in `~/.config/rex/init.lua` and `rex config reload` run.
