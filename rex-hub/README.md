# Rex Hub

**Run one coding agent from another—in a minimized floating pane you control.**
When Claude asks Codex to review a diff, or `agy` asks Claude to fix a failing
test, the delegated agent runs in a real Rex floating layer inside the same tab
instead of a blind shell script.

- **Stay in control:** every delegated agent starts minimized in the same tab.
  Expand it any time from `rex-sidecar`'s **Info → HUB** box (or via
  **Hub: Toggle Delegated Agent**) to watch live output, approve a prompt, or
  steer it directly—then minimize it back.
- **Two modes, chosen by the parent agent:**
  - **`oneshot`** (non-interactive): runs a single task, streams output to the
    float, saves the result, and auto-closes the floating layer when done.
  - **`interactive`**: runs the full agent TUI in the minimized float so the
    parent agent can have a multi-turn conversation (`hub_send` / `hub_read`)
    and decide when to close it (`hub_stop`).
- **No extra clutter:** delegated agents never open a second `rex-sidecar` or
  `rex-crab-pond` pane—they appear in the tab's existing sidecar (its HUB box)
  and crab pond.

**Try it:** add `require("extensions.rex-hub")` to `~/.config/rex/init.lua` and
run `rex config reload`.

## Actions

Any agent (or shell) inside Rex can call these with `rex do`:

| Action | Arguments | What it does |
| --- | --- | --- |
| `hub_run` | `agent=claude\|codex\|agy\|pi\|opencode` `task=...` `[mode=oneshot\|interactive]` `[cwd=...]` `[model=...]` `[wait=true\|false]` `[timeout=600]` | Spawns the agent in a minimized floating layer in the same tab. Defaults to `mode=oneshot`: waits up to 25 s (Rex ends a `rex do` action at 30 s) and returns the answer, or `status: running` and the `id` to poll with `hub_status`. A oneshot run is ended as `timeout` after `timeout` seconds (default 600). For `mode=interactive`, defaults to `wait=false`, has no time limit and stays open until stopped |
| `hub_send` | `id=...` `message=...` | Sends a follow-up message into an interactive Hub agent's pane |
| `hub_read` | `id=...` `[lines=120]` | Reads the saved output (oneshot) or recent terminal screen (interactive) of a Hub agent |
| `hub_status` | `[id=...]` `[parent=...]` | Reports live status (`running`, `done`, `failed`, `stopped`, `timeout`) and layer state (`minimized`, `normal`, `closed`) |
| `hub_toggle` | `[id=...]` `[open=true]` | Expands and focuses a minimized Hub float, or minimizes it back. `open=true` always expands and focuses it. Without `id`, toggles the newest active Hub agent in the current session |
| `hub_stop` | `id=...` | Stops the Hub agent and closes its floating layer |

### Examples

One-shot task (returns the answer when it's done within 25 s, the run `id` to poll otherwise):

```sh
rex do hub_run agent=codex task="Review auth.lua for race conditions"
```

Interactive multi-turn session (starts minimized, parent talks to it, then closes):

```sh
rex do hub_run agent=claude mode=interactive task="Help debug the flaky test in test.lua"
rex do hub_read id=claude-1795598212-589599
rex do hub_send id=claude-1795598212-589599 message="Try running only the parser suite"
rex do hub_stop id=claude-1795598212-589599
```

## Sidecar and Crab Pond integration

- **`rex-sidecar` (Info → `HUB`):** the pane's delegated runs get their own
  box, apart from its own subagents in AGENTS: the latest 8, newest first, each
  with the agent's colour (`[codex]`, `[claude]`, `[agy]`, `[pi]`,
  `[opencode]`), its task, mode and time. Click a run for its status and float
  state, then **`Open`** to show and focus its floating pane, **`Stop`** to
  close it, or **`View output`** once a oneshot run is done. A finished run
  shows ✓, a failed or timed-out one a red ✗, a stopped one a dim ■, and a
  running one a pulsing ●.
- **`rex-crab-pond`:** delegated agents appear inside the tab's existing pond
  without opening a second pond.
- **`rex-resume`:** Hub floating panes are skipped when saving snapshots.

## Run files

Each run keeps its files in `~/.config/rex/state/hub/`: `<id>.json` with the
run's details, `<id>.md` with a oneshot run's answer (its standard output, which
**View output** opens like an artifact), `<id>.err` with its errors, and
`<id>.exit` with how the agent ended. Files of runs that ended more than 7 days
ago are deleted when the next run starts.

## Skill

The [rex-hub skill](../plugins/rex-hub/README.md) teaches Claude Code and `agy`
to use these actions when you ask them to consult or hand work to another
agent, while their own subagents keep running the usual way.

## Install

The agent CLIs you delegate to must be on your login shell's `PATH`, as in a
new terminal: the float runs them through it.

1. Follow the [repository install guide](../README.md#install).
2. Add this line to `~/.config/rex/init.lua`:

   ```lua
   require("extensions.rex-hub")
   ```

3. Run `rex config reload`. If you already had `rex-sidecar`, `rex-crab-pond`,
   or `rex-resume` running, restart their watchers so they ignore `"Hub: "`
   floating panes:

   ```sh
   pkill -f 'extensions/.*/watcher\.lua'; rex config reload
   ```

## Tests

```sh
rex do ~/.config/rex/extensions/rex-hub/test.lua
```
