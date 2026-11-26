-- Unit tests for rex-hub/core.lua. Runs with `rex do rex-hub/test.lua` and
-- does not touch live Rex sessions or ~/.config/rex/state/hub.

local dir = debug.getinfo(1, "S").source:match("^@?(.*/)") or "./"
local tmp = "/tmp/rex-hub-test-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
REX_HUB_STATE_DIR = tmp

local core = dofile(dir .. "core.lua")

local function equal(got, want, msg)
	if got ~= want then
		error((msg or "mismatch") .. ": got " .. tostring(got) .. ", want " .. tostring(want), 2)
	end
end

local function list_equal(got, want, msg)
	equal(rex.json.encode(got), rex.json.encode(want), msg)
end

-- Labels
equal(core.is_hub_label("Hub: codex · Review auth"), true, "hub label detected")
equal(core.is_hub_label("Sidecar: rex"), false, "sidecar label not hub")
equal(core.is_hub_label(nil), false, "nil label not hub")
equal(core.hub_label("codex", "Review auth.lua"), "Hub: codex · Review auth.lua", "short hub label")
equal(#core.hub_label("claude", string.rep("a", 80)) < 60, true, "long hub label clipped")

-- ANSI stripping
equal(core.strip_ansi("\27[32mhello\27[0m\r\nworld"), "hello\nworld", "strip ansi")

-- Command building: oneshot vs interactive for all 5 agents
list_equal(core.build_command("claude", "oneshot", "Fix bug", "opus"), { "claude", "--model", "opus", "-p", "Fix bug" }, "claude oneshot")
list_equal(core.build_command("claude", "interactive", "Fix bug"), { "claude", "Fix bug" }, "claude interactive")
list_equal(core.build_command("codex", "oneshot", "Review", "gpt-5"), { "codex", "exec", "-m", "gpt-5", "Review" }, "codex oneshot")
list_equal(core.build_command("codex", "interactive", "Review"), { "codex", "Review" }, "codex interactive")
list_equal(core.build_command("agy", "oneshot", "Check"), { "agy", "-p", "Check" }, "agy oneshot")
list_equal(core.build_command("agy", "interactive", "Check"), { "agy", "-i", "Check" }, "agy interactive")
list_equal(core.build_command("pi", "oneshot", "Test"), { "pi", "-p", "Test" }, "pi oneshot")
list_equal(core.build_command("pi", "interactive", "Test"), { "pi", "Test" }, "pi interactive")
list_equal(core.build_command("opencode", "oneshot", "Audit", "m1"), { "opencode", "run", "-m", "m1", "Audit" }, "opencode oneshot")
list_equal(core.build_command("opencode", "interactive", "Audit"), { "opencode", "--prompt", "Audit" }, "opencode interactive")

local bad, berr = core.build_command("unknown", "oneshot", "hi")
equal(bad, nil, "unknown agent rejected")
equal(berr:find("unsupported agent", 1, true) ~= nil, true, "unknown agent error")

local empty, eerr = core.build_command("codex", "oneshot", "")
equal(empty, nil, "empty oneshot task rejected")
equal(eerr:find("task is required", 1, true) ~= nil, true, "empty task error")

-- Persistence and filtering
local r1 = { id = "codex-1", agent = "codex", mode = "oneshot", task = "t1", parent_block_id = "b1", session_id = "s1", started = 100, status = "done" }
local r2 = { id = "agy-2", agent = "agy", mode = "interactive", task = "t2", parent_block_id = "b1", session_id = "s1", started = 200, status = "running" }
local r3 = { id = "pi-3", agent = "pi", mode = "oneshot", task = "t3", parent_block_id = "b2", session_id = "s2", started = 150, status = "running" }
core.save_run(tmp, r1)
core.save_run(tmp, r2)
core.save_run(tmp, r3)

equal(core.load_run(tmp, "codex-1").task, "t1", "load saved run")
local b1_runs = core.list_runs(tmp, { parent_block_id = "b1" })
equal(#b1_runs, 2, "filtered by parent_block_id")
equal(b1_runs[1].id, "codex-1", "sorted oldest first")
equal(b1_runs[2].id, "agy-2", "sorted oldest first (2)")

-- Output reading
local out_path = core.result_path(tmp, "codex-1")
local f = assert(io.open(out_path, "w"))
f:write("\27[36mAll tests pass\27[0m\n")
f:close()
equal(core.read_output_file(out_path), "All tests pass", "read_output_file strips ansi")

-- Labels and output tails keep whole UTF-8 characters.
local ru = core.hub_label("claude", string.rep("я", 50))
equal(ru, "Hub: claude · " .. string.rep("я", 35) .. "…", "a Cyrillic label is cut on a character")
local tail_path = core.result_path(tmp, "pi-3")
f = assert(io.open(tail_path, "w"))
f:write(string.rep("я", 10))
f:close()
equal(core.read_output_file(tail_path, 5), "…(truncated)…\n" .. "яя", "an output tail starts on a character")

-- Command safety
list_equal(core.build_command("claude", "oneshot", "-x then @y"), { "claude", "-p", " -x then @y" }, "a task starting with - stays a prompt")
list_equal(core.build_command("pi", "oneshot", "@file"), { "pi", "-p", " @file" }, "a task starting with @ stays a prompt")
equal(core.build_command("codex", "interative", "x"), nil, "a misspelt mode is rejected")
equal(core.build_command("opencode", "interactive", "x", "m1"), nil, "opencode's TUI takes no model")

-- Run IDs
equal(core.valid_id("codex-1-2"), true, "a run id")
equal(core.valid_id("../x"), false, "a path is no run id")
equal(core.load_run(tmp, "../codex-1"), nil, "a path isn't loaded")
equal(core.new_id("codex", tmp) ~= core.new_id("codex", tmp), true, "new ids differ")

-- The wrapper's exit record fills in a running run, and leaves an ended one.
f = assert(io.open(core.exit_path(tmp, "agy-2"), "w"))
f:write("failed 127 300\n")
f:close()
local merged = core.load_run(tmp, "agy-2")
equal(merged.status, "failed", "the exit record ends a running run")
equal(merged.exit_code, 127, "with its exit code")
equal(merged.layer_state, "closed", "and its float closed")
f = assert(io.open(core.exit_path(tmp, "codex-1"), "w"))
f:write("stopped 129 300\n")
f:close()
equal(core.load_run(tmp, "codex-1").status, "done", "an ended run keeps its status")
equal(core.load_run(tmp, "codex-1").exit_code, 129, "and gets the exit code it lacked")

-- Pruning
core.save_run(tmp, { id = "old-1", started = 1, finished = 2, status = "done" })
core.save_run(tmp, { id = "old-2", started = 1, status = "running" })
core.prune(tmp, 7)
equal(core.load_run(tmp, "old-1"), nil, "an old ended run is pruned")
equal(core.load_run(tmp, "old-2") ~= nil, true, "a running one is kept")

-- Cleanup
rex.exec({ "/bin/rm", "-rf", tmp }, { timeout = 5 })
return "rex-hub: all tests passed"
