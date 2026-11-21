-- Run: rex do ~/.config/rex/extensions/cc-sidecar/test.lua
-- Mocks the Rex API: it doesn't touch live sessions or panes.
local real = rex
local dir = debug.getinfo(1, "S").source:match("^@?(.*/)")

local function equal(actual, expected, what)
	if actual ~= expected then
		error(what .. ": " .. tostring(actual) .. " ~= " .. tostring(expected), 2)
	end
end

local function terminal(id, label)
	return { block_id = id, label = label, creator_name = "com.superlogical.terminal", placement = "placed" }
end

local clients, blocks, processes, splits, closed, handlers, timers, stopped, next_id, resized

local function reset()
	clients, splits, closed, handlers, timers, stopped, next_id, resized = {}, {}, {}, {}, {}, false, 0, {}
	blocks = {
		terminal("block:1", "shell"),
		terminal("block:2", "shell"),
		terminal("block:8", "Sidecar: old"),
		terminal("block:9", "Changes: renamed"),
	}
	processes = {
		["block:1"] = { foreground = { argv0 = "claude", cwd = "/src/app/sub" } },
		["block:2"] = { foreground = { argv0 = "nvim", cwd = "/src/app" } },
	}
end


-- settings.json in a throwaway folder, never the real one.
local test_base = real.exec({ "mktemp", "-d" }).stdout:gsub("%s+$", "") .. "/"
CC_SIDECAR_TEST_BASE = test_base
local S = dofile(dir .. "settings.lua")
local poll

local function request_show(block_id)
	S.request_show(test_base, "session:1", block_id)
	poll()
end

local function run()
	local ok, err = pcall(assert(loadfile(dir .. "watcher.lua")))
	if not ok and err ~= "STOP" then
		error(err, 0)
	end
end

local function emit(event, block_id, payload)
	handlers[event]({ session_id = "session:1", block_id = block_id }, payload)
end

--- Sends a foreground change for a block.
local function foreground(block_id, argv0, cwd, ancestors)
	emit("terminal.process_changed", block_id, { foreground = { argv0 = argv0, cwd = cwd }, ancestors = ancestors })
end

local function user_closes(block_id)
	emit("block_closed", nil, { block_id = block_id })
end

--- Runs the timers that are due, as rex.after would.
local function fire()
	local due = timers
	timers = {}
	for _, fn in ipairs(due) do
		fn()
	end
end

rex = {
	call = function(method, params)
		if method == "client.list" then
			return { clients = clients }
		elseif method == "client.set_label" or method == "session.attach" then
			return {}
		elseif method == "session.list" then
			return { sessions = { { session_id = "session:1" } } }
		elseif method == "session.list_blocks" then
			return { blocks = blocks }
		elseif method == "session.new_split" then
			next_id = next_id + 1
			table.insert(splits, params)
			return { block_ids = { "block:sidecar" .. next_id } }
		elseif method == "block.close" then
			table.insert(closed, params.block_id)
			return {}
		elseif method == "session.resize_pane" then
			table.insert(resized, params)
			return {}
		end
		error("unexpected call " .. method)
	end,
	block = {
		call = function(_, _, params)
			return processes[params.block_id]
		end,
	},
	exec = function(argv)
		local cwd = argv[3]
		if cwd:match("^/src/app") then
			return { ok = true, stdout = "/src/app\n" }
		end
		return { ok = false, stdout = "" }
	end,
	on = function(event, fn)
		handlers[event] = fn
	end,
	every = function(_, fn)
		poll = fn
	end,
	after = function(_, fn)
		table.insert(timers, fn)
	end,
	log = function() end,
	json = real.json,
	stop = function()
		stopped = true
		error("STOP", 0)
	end,
}

local ok, err = pcall(function()
	-- At start, closes stale sidecar panes and opens one beside a running Claude.
	reset()
	run()
	equal(closed[1], "block:8", "stale pane closed")
	equal(closed[2], "block:9", "pane from before the rename closed")
	equal(#splits, 1, "panes opened at start")
	local split = splits[1]
	equal(split.anchor_id, "block:1", "anchor")
	equal(split.direction, "horizontal", "direction")
	equal(split.side, "after", "side")
	equal(split.ratio, 0.7, "ratio")
	equal(split.focus, false, "focus")
	equal(split.layout.block.label, "Sidecar: app", "label")
	equal(split.layout.block.options.cwd, "/src/app", "cwd is the repository root")
	local command = split.layout.block.options.command
	equal(command[3], "do", "viewer runs with rex do")
	equal(command[4], dir .. "panel.lua", "viewer")
	equal(command[5], "claude=block:1", "viewer's Claude pane")
	equal(command[6], "cwd=/src/app", "viewer's repository")
	fire()
	equal(resized[1].before_block_id, "block:1", "resized left")
	equal(resized[1].after_block_id, "block:sidecar1", "resized right")
	equal(resized[1].ratio, 0.7, "resized ratio")

	-- The same Claude doesn't get a second pane, and a command it runs in the
	-- foreground doesn't close it.
	foreground("block:1", "claude", "/src/app/sub")
	foreground("block:1", "git", "/src/app", { { argv0 = "claude" }, { argv0 = "-zsh" } })
	equal(#splits, 1, "panes after repeated events")
	equal(#closed, 2, "closed while Claude runs")

	-- Claude exiting closes its pane.
	foreground("block:1", "-zsh", "/src/app", { { argv0 = "login" } })
	equal(closed[3], "block:sidecar1", "pane closed on exit")

	-- Claude outside a repository gets a pane in its own directory.
	foreground("block:2", "/usr/local/bin/claude", "/tmp")
	equal(#splits, 2, "pane outside a repository")
	equal(splits[2].layout.block.label, "Sidecar: tmp", "label outside a repository")
	equal(splits[2].layout.block.options.command[6], "cwd=/tmp", "directory outside a repository")
	user_closes("block:2")

	-- A pane the user closes stays closed until Claude starts again.
	foreground("block:1", "claude", "/src/app")
	equal(#splits, 3, "pane for a new Claude")
	user_closes("block:sidecar3")
	foreground("block:1", "claude", "/src/app")
	equal(#splits, 3, "reopened after the user closed it")
	foreground("block:1", "-zsh", "/src/app")
	equal(#closed, 4, "closed a pane that is already gone")
	foreground("block:1", "claude", "/src/app")
	equal(#splits, 4, "pane for the next Claude")

	-- Closing the Claude pane closes its sidecar pane.
	user_closes("block:1")
	equal(closed[5], "block:sidecar4", "pane closed with its Claude pane")

	-- A pane whose login shell execs Claude is found by the recheck, once,
	-- however its name is cased.
	fire()
	equal(#timers, 0, "rechecks before")
	processes["block:3"] = { foreground = { argv0 = "Claude", cwd = "/src/app" } }
	foreground("block:3", "/bin/zsh", "/src/app")
	equal(#splits, 4, "pane before the recheck")
	fire()
	equal(#splits, 5, "pane after the recheck")
	equal(splits[5].anchor_id, "block:3", "rechecked anchor")
	processes["block:3"] = { foreground = { argv0 = "-zsh", cwd = "/src/app" } }
	foreground("block:3", "-zsh", "/src/app")
	equal(closed[6], "block:sidecar5", "rechecked pane closed")
	fire()
	fire()
	equal(#timers, 0, "rechecks repeat")

	-- A second copy quits.
	reset()
	clients = { { info = { label = "cc-sidecar" } } }
	run()
	equal(stopped, true, "second copy stopped")
	equal(#splits, 0, "second copy's panes")

	-- Settings: on until turned off, other keys kept, bad JSON means on.
	equal(S.auto_show(test_base), true, "on with no settings file")
	local f = assert(io.open(test_base .. "settings.json", "w"))
	f:write('{"other": 1}')
	f:close()
	S.set_auto_show(test_base, false)
	equal(S.auto_show(test_base), false, "saved off")
	f = assert(io.open(test_base .. "settings.json"))
	equal(rex.json.decode(f:read("*a")).other, 1, "other settings kept")
	f:close()
	f = assert(io.open(test_base .. "settings.json", "w"))
	f:write("{broken")
	f:close()
	equal(S.auto_show(test_base), true, "on with a broken file")
	equal(S.tree(test_base), false, "list until the tree is chosen")
	S.set_tree(test_base, true)
	equal(S.tree(test_base), true, "tree saved")

	-- Auto-show off: Claude gets no pane until asked for one.
	S.set_auto_show(test_base, false)
	reset()
	blocks[1].window_id, blocks[2].window_id = "window:1", "window:1"
	run()
	equal(#splits, 0, "no pane with auto-show off")
	poll()
	equal(#splits, 0, "no request, no pane")
	request_show("block:1")
	equal(#splits, 1, "shown for the focused Claude")
	equal(splits[1].anchor_id, "block:1", "beside that Claude")
	equal(io.open(test_base .. "show-request.json"), nil, "request used up")
	request_show("block:1")
	equal(#splits, 1, "already shown")
	request_show("block:sidecar1")
	equal(#splits, 1, "asked from the sidecar pane itself")

	-- From another pane in the tab, it means the Claude there.
	reset()
	blocks[1].window_id, blocks[2].window_id = "window:1", "window:1"
	run()
	request_show("block:2")
	equal(#splits, 1, "shown for the tab's Claude")
	equal(splits[1].anchor_id, "block:1", "the tab's Claude")

	-- A tab without Claude gets nothing.
	reset()
	blocks[1].window_id, blocks[2].window_id = "window:1", "window:2"
	run()
	request_show("block:2")
	equal(#splits, 0, "no Claude in the tab")
	S.set_auto_show(test_base, true)
end)
rex = real
real.exec({ "rm", "-rf", test_base })
CC_SIDECAR_TEST_BASE = nil
if not ok then
	error(err, 0)
end

-- The viewer, on a made-up transcript.
CC_SIDECAR_TEST = true
local P = dofile(dir .. "panel.lua")
CC_SIDECAR_TEST = nil

local function plain(lines)
	return (table.concat(lines, "\n"):gsub("\27%[[%d;?]*%a", ""))
end

local function has(text, part, what)
	if not text:find(part, 1, true) then
		error(what .. ": no " .. part .. " in:\n" .. text, 2)
	end
end

local function hasnt(text, part, what)
	if text:find(part, 1, true) then
		error(what .. ": " .. part .. " in:\n" .. text, 2)
	end
end

local function use(id, name, input)
	return { type = "assistant", message = { model = "claude-test", content = { { type = "tool_use", id = id, name = name, input = input } } } }
end

local function result(id, content, extra, is_error, decision)
	return {
		type = "user",
		toolUseResult = extra,
		permissionDecision = decision,
		message = { content = { { type = "tool_result", tool_use_id = id, content = content, is_error = is_error } } },
	}
end

local records = {
	{ type = "ai-title", aiTitle = "Panel tabs" },
	{ type = "user", gitBranch = "main", message = { content = "Add tabs to the panel" } },
	{ type = "user", isMeta = true, message = { content = "skill text" } },
	{ type = "user", message = { content = "<task-notification>done</task-notification>" } },
	{ type = "user", message = { content = "<command-name>/review</command-name><command-args>high</command-args>" } },
	{ type = "attachment", attachment = { type = "queued_command", prompt = "Also add a hint" } },
	{ type = "user", message = { content = { { type = "text", text = "Also add a hint" } } } },
	use("q1", "AskUserQuestion", { questions = { { question = "Which tabs?" } } }),
	result("q1", "answered", { answers = { ["Which tabs?"] = "Diff and Context" }, annotations = { ["Which tabs?"] = { notes = "keep Diff first" } } }),
	use("p1", "ExitPlanMode", { plan = "# Tabbed panel\nsteps" }),
	result("p1", "approved", {}),
	use("r1", "Bash", { command = "rm -rf build" }),
	result("r1", "The user doesn't want to proceed with this tool use. To tell you how to proceed, the user said:\nkeep build", nil, true,
		{ decision = "reject", source = "user_reject" }),
	use("t1", "TaskCreate", { subject = "Write the parser" }),
	result("t1", "Task #1 created successfully"),
	use("t2", "TaskCreate", { subject = "Draw the tabs" }),
	result("t2", "Task #2 created successfully"),
	use("u1", "TaskUpdate", { taskId = "1", status = "completed" }),
	use("w1", "TodoWrite", { todos = { { content = "Update the README", status = "in_progress" } } }),
	use("e1", "Edit", { file_path = "/src/app/panel.lua" }),
	result("e1", "ok"),
	use("e2", "Edit", { file_path = "/src/app/panel.lua" }),
	result("e2", "ok"),
	use("e3", "Write", { file_path = "/src/app/gone.lua" }),
	result("e3", "denied", nil, true),
	use("b1", "Bash", { command = "cd /src/app && rex do test.lua" }),
	result("b1", "Exit code 1\nboom: parser", nil, true),
	use("b2", "Bash", { command = "cat test.lua" }),
	result("b2", "ok"),
	{ type = "user", isSidechain = true, message = { content = "subagent prompt" } },
	{ type = "system", subtype = "compact_boundary" },
	{ type = "system", subtype = "turn_duration", durationMs = 125000 },
	{ type = "user", isCompactSummary = true, message = { content = "Summary:\n## Requests\n- old\n## Current state\n- parser done\n\nIf you need specific details from before compaction, read it." } },
	use("q2", "AskUserQuestion", { questions = { { question = "Ship it now?" } } }),
	{ type = "assistant", message = { content = { { type = "text", text = "Done.\n- **Should I also add a third tab?**" } }, usage = { input_tokens = 2, cache_read_input_tokens = 40000, cache_creation_input_tokens = 1000 } } },
}
local lines = {}
for _, r in ipairs(records) do
	lines[#lines + 1] = rex.json.encode(r)
end
-- API request records aren't decoded, so a broken one doesn't matter.
table.insert(lines, 2, '{"type":"api-request-blob","message":broken')
local text = table.concat(lines, "\n") .. "\n"

local ok2, err2 = pcall(function()
	-- A line split between reads is kept until its end arrives.
	local state = P.new_state()
	P.feed(state, text:sub(1, 200))
	P.feed(state, text:sub(201))
	equal(state.partial, "", "nothing left over")
	equal(state.title, "Panel tabs", "title")
	equal(state.branch, "main", "branch")
	equal(state.model, "claude-test", "model")
	equal(state.context, 41002, "context")
	equal(state.compactions, 1, "compactions")

	local info = plain(P.info_lines(state, 60))
	equal(#state.prompts, 3, "prompts, without meta, notices, a prompt recorded twice, or subagents")
	has(info, "? Ship it now?", "waiting question")
	has(info, "? Should I also add a third tab?", "question in the last reply")
	has(info, "○ Draw the tabs", "open task")
	hasnt(info, "Write the parser", "completed task")
	has(info, "▸ Update the README", "todo in progress")
	local this_turn = plain({ P.turn_patch(state, "/src/app/panel.lua", "panel.lua") })
	has(this_turn, "panel.lua", "edit in the turn")
	equal(state.turn.files["/src/app/gone.lua"], nil, "failed write")

	-- A prompt after the reply answers its questions.
	P.feed(state, rex.json.encode({ type = "user", message = { content = "No third tab" } }) .. "\n")
	hasnt(plain(P.info_lines(state, 60)), "third tab?", "answered reply question")

	local activity = plain(P.info_lines(state, 60, { show = "tests" }))
	has(activity, "tests 1 ✓0 ✗1", "test totals in the receipt")
	has(activity, "✗ rex do test.lua", "failed test, listed")
	hasnt(activity, "cat test.lua", "a command that only names a test file")
	has(plain(P.info_lines(state, 60, { show = "failed" })), "exit 1: boom: parser", "failure, listed")
	hasnt(plain(P.info_lines(state, 60)), "exit 1: boom", "lists closed by default")
	has(activity, "claude 2m", "Claude time")
	has(activity, "ctx 41k", "context")
	has(activity, "Panel tabs · main", "title and branch")
	has(activity, "✗ 1 denied", "the rejected command, denied at the gate")
	has(activity, "f: file 0  s: shell 1  o: other 0", "gate families")

	-- Reading a file: only new bytes on the next read, and a reset when
	-- the file shrinks.
	local path = os.tmpname()
	local f = io.open(path, "wb")
	f:write(text)
	f:close()
	local read = P.new_state()
	P.read_new(read, path)
	equal(#read.prompts, 3, "prompts read from the file")
	equal(read.offset, #text, "offset")
	P.read_new(read, path)
	equal(#read.prompts, 3, "prompts after reading again")
	f = io.open(path, "wb")
	f:write("{}\n")
	f:close()
	equal(P.read_new(read, path), "reset", "shorter file")
	os.remove(path)

	-- Tests are told from commands that only mention them.
	equal(P.test_command("cd /a && xcodebuild -scheme X test | tail"), "xcodebuild -scheme X test", "xcodebuild test")
	equal(P.test_command("FOO=1 npm test"), "FOO=1 npm test", "npm test")
	equal(P.test_command("grep test x"), nil, "grep")
	equal(P.test_command('rex do -e "TEST=true"'), nil, "a word with test that isn't a file")

	-- Text helpers.
	equal(P.width("\27[1mé ✓\27[0m"), 3, "width")
	equal(P.clip("\27[31mabcdef", 3), "\27[31mabc\27[0m", "clip")
	equal(P.clip("a\27[H\27[2Jb\27c\7d", 9), "abcd", "clip drops cursor moves and control characters")
	local quoted = P.new_state()
	P.feed(quoted, '{"type":"user","message":{"role":"user","content":"hi \\u001b[H\\u001b[31mthere"}}\n')
	equal(quoted.prompts[1].text, "hi there", "transcript text without terminal codes")
	-- A new file with a line of over a million characters, which a pattern
	-- can't match.
	local long = P.new_state()
	local huge = string.rep("x", 1200000)
	P.feed(long, rex.json.encode(use("n1", "Write", { file_path = "/src/app/data.txt" })) .. "\n"
		.. rex.json.encode(result("n1", "ok", { type = "create", content = "head\n" .. huge .. "\n" })) .. "\n")
	local created = long.turn.files["/src/app/data.txt"]
	equal(created.added, 2, "lines of a new file with a very long line")
	equal(created.hunks[1].lines[2], "+" .. huge, "the very long line")
	local wrapped = P.wrap("one two three four", 9, "> ", "  ")
	equal(wrapped[1], "> one two", "wrap line 1")
	equal(wrapped[2], "  three", "wrap line 2")
	equal(#P.wrap("a\nb\nc\nd", 20, "", "", 2), 2, "max lines")
	equal(P.wrap("abcdefghij", 6, "> ", "  ")[2], "  efgh", "long word cut")
	equal(P.project_dir("/Users/a.b/My App"), "-Users-a-b-My-App", "project folder")
	equal(P.claude_pid({ foreground = { argv0 = "git" }, ancestors = { { argv0 = "/bin/claude", pid = 7 } } }), 7, "pid")

	-- The status, from one porcelain call.
	local st = P.status("## main...origin/main [ahead 1]\0 M a.lua\0R  new.lua\0old.lua\0?? docs/x.md\0MM both.lua\0")
	equal(st.branch, "main", "branch name")
	equal(#st.files, 4, "changed files")
	equal(st.files[2].path, "new.lua", "rename's new path")
	equal(st.head, true, "branch with commits")
	local empty = P.status("## No commits yet on main\0")
	equal(empty.head, false, "branch without commits")
	equal(empty.branch, "main", "branch without commits' name")

	-- Uncommitted: a file changed both ways is in both groups, once in the tree.
	local data = P.uncommitted(st.files)
	equal(data.groups[1].title, "Staged", "first group")
	equal(#data.groups[1].rows, 2, "staged rows")
	equal(data.groups[2].title, "Unstaged", "second group")
	equal(#data.groups[2].rows, 3, "unstaged rows")
	equal(#data.merged, 4, "tree rows")
	equal(data.groups[2].rows[2].mark, "A", "untracked counts as added")
	equal(#P.uncommitted({}).groups, 0, "nothing changed")

	-- Each row's diff.
	local args = function(row, ...)
		return table.concat(P.diff_args(row, ...), " ")
	end
	equal(args({ path = "a", diff = "staged" }), "diff --cached -- a", "staged diff")
	equal(args({ path = "a", diff = "unstaged" }), "diff -- a", "unstaged diff")
	equal(args({ path = "a", diff = "head" }, nil, true), "diff HEAD -- a", "merged diff")
	equal(args({ path = "a", diff = "head" }, nil, false), "diff --cached -- a", "merged diff without commits")
	equal(args({ path = "a", diff = "base" }, "abc"), "diff abc -- a", "branch diff")
	equal(args({ path = "a", diff = "untracked" }), "diff --no-index -- /dev/null a", "untracked diff")

	-- Numbers and the Branch scope.
	local a2, r2 = P.numstat("3\t1\ta.lua\0-\t-\tpic.png\0" .. "2\t0\tb c.lua\0")
	equal(a2, 5, "added")
	equal(r2, 1, "removed")
	local moved_a, moved_r = P.numstat("1\t2\t\0old.lua\0new.lua\0")
	equal(moved_a, 1, "added in a rename")
	equal(moved_r, 2, "removed in a rename")
	local renamed = P.branch_rows("R100\0old.lua\0new.lua\0M\0z.lua\0", {})
	equal(#renamed, 2, "a rename is one row")
	equal(renamed[1].path, "new.lua", "a rename's new path")
	equal(renamed[1].mark, "R", "rename mark")
	local branch = P.branch_rows("M\0z.lua\0D\0b.lua\0", { { x = "?", y = "?", path = "c.lua" }, { x = " ", y = "M", path = "z.lua" } })
	equal(#branch, 3, "branch rows with untracked")
	equal(branch[1].path, "b.lua", "sorted")
	equal(branch[1].mark, "D", "branch mark")
	equal(branch[2].diff, "untracked", "untracked in the branch")

	-- Last Turn: edits since the last prompt, with Claude Code's hunks.
	local turn = P.new_state()
	local function edit(id, path, extra)
		P.record(turn, use(id, "Edit", { file_path = path }))
		P.record(turn, result(id, "ok", extra))
	end
	edit("x1", "/src/app/old.lua", { structuredPatch = { { oldStart = 1, oldLines = 1, newStart = 1, newLines = 1, lines = { "-a", "+b" } } } })
	P.record(turn, { type = "user", message = { content = "Next task" } })
	equal(#P.turn_data(turn, "/src/app").groups, 0, "a prompt starts a new turn")
	has(P.turn_data(turn, "/src/app").note, "No edits", "empty turn's note")
	edit("x2", "/src/app/a.lua", { structuredPatch = { { oldStart = 3, oldLines = 2, newStart = 3, newLines = 2, lines = { " k", "-a", "+b", "+c" } } } })
	edit("x3", "/src/app/a.lua", { structuredPatch = { { oldStart = 9, oldLines = 1, newStart = 9, newLines = 0, lines = { "-z" } } } })
	P.record(turn, use("x4", "Write", { file_path = "/src/app/new.lua" }))
	P.record(turn, result("x4", "ok", { type = "create", content = "one\ntwo\n", structuredPatch = {} }))
	local td = P.turn_data(turn, "/src/app")
	equal(#td.groups[1].rows, 2, "files this turn")
	equal(td.groups[1].rows[1].path, "a.lua", "relative path")
	equal(td.groups[1].rows[1].mark, "M", "edited file")
	equal(td.groups[1].rows[2].mark, "A", "new file")
	equal(td.added, 4, "turn's added lines")
	equal(td.removed, 2, "turn's removed lines")
	local patch = P.turn_patch(turn, "/src/app/a.lua", "a.lua")
	has(patch, "diff --git a/a.lua b/a.lua\n--- a/a.lua\n+++ b/a.lua\n", "patch names the file")
	has(patch, "@@ -3,2 +3,2 @@\n k\n-a\n+b\n+c\n", "first hunk")
	has(patch, "@@ -9,1 +9,0 @@\n-z\n", "second hunk")
	has(P.turn_patch(turn, "/src/app/new.lua", "new.lua"), "@@ -0,0 +1,2 @@\n+one\n+two\n", "new file's hunk")

	-- The Changes view: pinned header, grouped list and clickable rows.
	local v = { title = "feature/x", scope = "Uncommitted", scopes = P.scopes(true, "Branch"), data = data }
	data.added, data.removed = 7, 2
	local built = P.changes_view(v, 40)
	equal(#built.pinned, 4, "pinned lines")
	has(plain({ built.pinned[1] }), "feature/x", "branch")
	has(plain({ built.pinned[1] }), "+7 −2", "totals")
	equal(P.width(built.pinned[1]), 40, "header fills the width")
	has(plain({ built.pinned[1] }), "╭ feature/x", "the header is a box")
	has(plain({ built.pinned[2] }), "Last Turn", "scopes inside it")
	has(plain({ built.pinned[3] }), "╰", "its bottom line")
	has(plain(built.lines), "Staged 2", "staged box")
	has(plain(built.lines), "Unstaged 3", "unstaged box")
	equal(P.width(built.lines[1]), 40, "a box fills the width")
	has(plain(built.lines), "A x.md  docs", "row with its folder")
	equal(built.rows[1].row.diff, "staged", "first row")
	equal(built.actions[built.rows[1].line].kind, "open", "row is clickable")
	v.selected = built.rows[1].key
	has(plain(P.changes_view(v, 40).lines), "› ", "selected row")
	equal(table.concat(P.scopes(false), ","), "Last Turn", "scopes without git")
	equal(table.concat(P.scopes(true, "PR"), ","), "Last Turn,Uncommitted,PR", "a PR instead of Branch")
	equal(table.concat(P.scopes(true), ","), "Last Turn,Uncommitted", "no Branch on the default branch")
	equal(P.pick_scope(P.scopes(true, "PR"), "Branch"), "PR", "Branch moves to PR")
	equal(P.pick_scope(P.scopes(true, "Branch"), "PR"), "Branch", "PR moves to Branch")
	equal(P.pick_scope(P.scopes(true), "Branch"), "Last Turn", "Branch gone on the default branch")
	equal(P.pick_scope(P.scopes(true), "Uncommitted"), "Uncommitted", "a scope that stays")
	local pr = P.pr_info('{"number":12,"baseRefName":"develop","state":"OPEN"}')
	equal(pr and pr.number, 12, "PR number")
	equal(pr and pr.base, "develop", "PR base")
	equal(P.pr_info('{"number":12,"baseRefName":"develop","state":"MERGED"}'), nil, "merged PR")
	equal(P.pr_info('{"number":12,"baseRefName":"--output=x","state":"OPEN"}'), nil, "a base that reads as an option")
	equal(P.pr_info("no pull requests found"), nil, "no PR")
	equal(P.pr_info(nil), nil, "gh failed")

	-- The tree merges the groups and lists folders.
	v.tree, v.selected = true, nil
	local tree = P.changes_view(v, 40)
	has(plain(tree.lines), "Changed 4", "tree box")
	has(plain(tree.lines), "▾ docs", "folder")
	local function files_of(view)
		local files = {}
		for _, r in ipairs(view.rows) do
			if r.row then
				files[#files + 1] = r
			end
		end
		return files
	end
	equal(#files_of(tree), 4, "tree's files")
	local diffs = {}
	for _, r in ipairs(files_of(tree)) do
		diffs[r.row.diff] = true
	end
	equal(diffs.head, true, "tree rows' diffs")
	local deep = P.changes_view({ title = "m", scope = "Branch", scopes = P.scopes(true, "Branch"), tree = true, data = { groups = { { title = "Changed", rows = {
		{ path = "src/cart/a.ts", mark = "M" }, { path = "src/cart/b.ts", mark = "A" }, { path = "src/ui/c.ts", mark = "M" }, { path = "z.ts", mark = "D" },
	} } }, vs = "main" } }, 30)
	local shown_tree = plain(deep.lines)
	has(shown_tree, "vs main", "what the branch compares with")
	local _, cart_count = shown_tree:gsub("▾ cart", "")
	equal(cart_count, 1, "a folder is listed once")
	has(shown_tree, "▾ ui", "sibling folder")
	has(shown_tree, "z.ts", "top-level file")

	-- Folders come before files at each level, each by name.
	local ordered = P.changes_view({ title = "m", scope = "Branch", scopes = P.scopes(true, "Branch"), tree = true, data = { groups = { { title = "Changed", rows = {
		{ path = "z.ts", mark = "M" }, { path = "a.ts", mark = "M" }, { path = "lib/x.ts", mark = "M" }, { path = "lib/sub/y.ts", mark = "M" },
		{ path = "lib/a.ts", mark = "M" }, { path = "lib-b/k.ts", mark = "M" }, { path = "app/m.ts", mark = "M" },
	} } }, note = "" } }, 40)
	local names = {}
	for _, r in ipairs(ordered.rows) do
		names[#names + 1] = r.dir or r.row.path
	end
	equal(table.concat(names, " "), "app app/m.ts lib lib/sub lib/sub/y.ts lib/a.ts lib/x.ts lib-b lib-b/k.ts a.ts z.ts", "tree order")

	-- Folders fold, and take what's under them along, nested folders included.
	local fold_rows = { { path = "src/cart/a.ts", mark = "M" }, { path = "src/cart/b.ts", mark = "M" }, { path = "src/ui/c.ts", mark = "A" }, { path = "z.ts", mark = "M" } }
	local function fold_view(folded, selected)
		return P.changes_view({ title = "m", scope = "Branch", scopes = P.scopes(true, "Branch"), tree = true, folded = folded, selected = selected,
			data = { groups = { { title = "Changed", rows = fold_rows } }, note = "" } }, 40)
	end
	local all_open = fold_view({})
	equal(#all_open.rows, 7, "folders and files are all rows")
	equal(all_open.rows[1].dir, "src", "a folder's row")
	equal(all_open.rows[2].dir, "src/cart", "a nested folder's path")
	equal(all_open.actions[all_open.rows[2].line].kind, "dir", "clicking a folder folds it")
	equal(all_open.actions[all_open.rows[2].line].path, "src/cart", "the folder clicked")
	local one = fold_view({ ["src/cart"] = true })
	has(plain(one.lines), "▸ cart (2)", "a folded folder counts its files")
	hasnt(plain(one.lines), "a.ts", "a folded folder hides its files")
	has(plain(one.lines), "c.ts", "a sibling folder stays open")
	has(plain(one.lines), "z.ts", "a file after the folder stays")
	local outer = fold_view({ src = true })
	has(plain(outer.lines), "▸ src (3)", "a folder counts files at every depth")
	hasnt(plain(outer.lines), "cart", "a folded folder hides nested folders")
	hasnt(plain(outer.lines), "c.ts", "and their files")
	has(plain(outer.lines), "z.ts", "a top-level file stays")
	equal(#outer.rows, 2, "only what's shown can be selected")
	has(plain(fold_view({}, "\0dir\0src").lines), "› ▾ src", "a selected folder")

	local dirs = dir .. "fold-dirs-test/"
	real.exec({ "mkdir", "-p", dirs })
	local SD = dofile(dir .. "settings.lua")
	local ok_dirs, err_dirs = pcall(function()
		SD.set_folded_dir(dirs, "/repo/a", "src", true)
		SD.set_folded_dir(dirs, "/repo/b", "lib", true)
		equal(SD.folded_dirs(dirs, "/repo/a").src, true, "folder fold saved")
		equal(SD.folded_dirs(dirs, "/repo/a").lib, nil, "per repository")
		SD.set_folded_dir(dirs, "/repo/a", "src", false)
		equal(next(SD.folded_dirs(dirs, "/repo/a")), nil, "folder unfold saved")
		equal(SD.folded_dirs(dirs, "/repo/b").lib, true, "another repository's folds kept")
	end)
	real.exec({ "rm", "-rf", dirs })
	if not ok_dirs then
		error(err_dirs, 0)
	end

	-- Narrow panes get the short scope names; the columns follow.
	local narrow, narrow_ranges = P.scope_bar(P.scopes(true, "Branch"), "Branch", 26)
	has(plain({ narrow }), "Local", "short name")
	hasnt(plain({ narrow }), "Uncommitted", "long name")
	equal(narrow_ranges[3].action.scope, "Branch", "last scope")
	local _, wide_ranges = P.scope_bar(P.scopes(true, "Branch"), "Branch", 60)
	equal(wide_ranges[1].from, 1, "first scope's column")
	equal(wide_ranges[2].from, wide_ranges[1].to + 2, "columns leave a space")

	-- Clicks land on what's drawn.
	local _, tab_ranges = P.frame(P.tabs, "Changes", {}, 0, 40, 10, { badges = { Changes = "3" } })
	local layout = { tabs = tab_ranges, hits = built.hits, pinned = 4, actions = built.actions, scroll = 0 }
	equal(P.hit(layout, 2, 1).tab, "Info", "click a tab")
	equal(P.hit(layout, 8, 1).tab, "Changes", "click the other tab")
	equal(P.hit(layout, 2, 2), nil, "click the blank row")
	equal(P.hit(layout, 38, 3).kind, "tree", "click the tree toggle")
	equal(P.hit(layout, 1, 4), nil, "click the header's border")
	equal(P.hit(layout, 4, 4).scope, "Last Turn", "click a scope")
	equal(P.hit(layout, 2, 6), nil, "click the blank pinned row")
	equal(P.hit(layout, 2, 7), nil, "click a box's top")
	equal(P.hit(layout, 5, 8).row.diff, "staged", "click a row")
	layout.scroll = 1
	equal(P.hit(layout, 5, 7).row.diff, "staged", "click a row when scrolled")

	-- Usage: hidden without the saved input, and a passed reset counts as unused.
	-- The main box: limits and cost from the status line's saved input, and a
	-- passed reset counts as unused.
	hasnt(plain(P.info_lines(P.new_state(), 40)), "5h", "no usage saved")
	local limits = { five_hour = { used_percentage = 58, resets_at = 1300 }, seven_day = { used_percentage = 17, resets_at = 500 } }
	local usage_state = P.new_state()
	usage_state.model, usage_state.context, usage_state.effort, usage_state.mode, usage_state.requests = "claude-opus-5-5", 250000, "high", "auto", 12
	local usage = plain(P.info_lines(usage_state, 60, { now = 1000, status = {
		rate_limits = limits, cost = { total_cost_usd = 3.456 }, context_window = { context_window_size = 1000000 } } }))
	has(usage, "Opus 5.5 · main", "the model's name")
	has(usage, "○ idle", "idle")
	has(usage, "effort ▮▮▮▯▯ high", "effort cells")
	has(usage, "mode auto", "permission mode")
	has(usage, "12 req", "requests")
	has(usage, "ctx ▰▰▱▱▱▱▱▱ 25% 250k/1.0M", "context against the window")
	hasnt(usage, "$", "no money")
	has(usage, "5h ▰▰▰▱▱ 58% ↻5m", "5-hour window and its reset")
	has(usage, "7d ▱▱▱▱▱ 0%", "a window that has reset")
	equal(P.model_name("claude-haiku-5-5"), "Haiku 5.5", "a model's name")
	equal(P.span(157), "2m37s", "a span")
	equal(P.clock(65), "1:05", "a clock")
	equal(P.tokens(1500), "2k", "tokens")
	equal(P.epoch("1970-01-01T00:01:05.123Z"), 65, "a timestamp")

	-- A float from an earlier diff is found by its label.
	local view = { windows = { { window_id = "w", layers = {
		{ layer_id = "t", kind = "tiled", blocks = { { block_id = "me", label = "Diff: tiled" } } },
		{ layer_id = "f", kind = "floating", blocks = { { block_id = "d", label = "Diff: a.lua" } } },
		{ layer_id = "o", kind = "floating", blocks = { { block_id = "o", label = "View: a.lua" } } },
		{ layer_id = "x", kind = "floating", blocks = { { block_id = "x", label = "scratch" } } },
	} } } }
	equal(P.window_of(view, "me").window_id, "w", "window of the pane")
	equal(table.concat(P.old_diffs(view.windows[1]), ","), "f,o", "earlier diff and Rex View floats, not others")

	-- After a float closes, focus comes back only if the tab is still in front.
	equal(P.float_closed(view, "d"), false, "float still open")
	equal(P.float_closed(view, "gone"), true, "float closed")
	view.active_window_id = "w"
	equal(P.is_active(view, "me"), true, "tab in front")
	view.active_window_id = "other"
	equal(P.is_active(view, "me"), false, "another tab in front")

	local tabs = P.tabs

	-- The frame fills the pane and no more, and says where it is when the
	-- lines don't fit.
	local frame = P.frame(tabs, "Changes", { "a", "b", "c", "d" }, 1, 60, 4)
	local _, count = frame:gsub("\r\n", "")
	equal(count, 3, "frame rows")
	has(frame, "\27[K\r\n\27[K\r\nb", "blank row under the tab bar")
	equal(P.width(P.frame(tabs, "Info", { string.rep("x", 60) }, 0, 40, 4):match("\r\n\27%[K\r\n(.-)\27%[K")), 39, "last column left free")
	has(frame, " Changes ", "tab bar")
	has(frame, "2–3 of 4", "position")
	hasnt(P.frame(tabs, "Info", { "a" }, 0, 40, 4), " of ", "position when everything fits")
	hasnt(frame, "\r\na\27", "scrolled past the first line")
	local with_pinned = P.frame(tabs, "Changes", { "a", "b" }, 0, 60, 4, { pinned = { "head" } })
	has(with_pinned, "head\27[K\r\na", "pinned line above the rows")
	has(with_pinned, "1–1 of 2", "pinned lines leave fewer rows")

	-- The reasoning level, the latest one, from Claude's own records only.
	local levels = P.new_state()
	P.record(levels, { type = "assistant", effort = "xhigh", message = { content = {} } })
	equal(levels.effort, "xhigh", "effort")
	P.record(levels, { type = "assistant", effort = "xhigh", perTurnEffort = "medium", message = { content = {} } })
	equal(levels.effort, "medium", "this turn's level wins")
	P.record(levels, { type = "assistant", isSidechain = true, perTurnEffort = "low", message = { content = {} } })
	equal(levels.effort, "medium", "a subagent's level is ignored")
	P.record(levels, { type = "assistant", message = { content = {} } })
	equal(levels.effort, "medium", "kept when a record has none")
	has(plain(P.info_lines(levels, 60)), "effort ▮▮▯▯▯ medium", "the effort in the main box")
	hasnt(plain(P.info_lines(P.new_state(), 60)), "effort", "no level known")

	-- Responses: a turn's last text, whole.
	local dated = P.new_state()
	local function say(text)
		return { type = "assistant", message = { content = { { type = "text", text = text } } } }
	end
	P.record(dated, { type = "user", message = { content = "first go" } })
	P.record(dated, say("thinking"))
	P.record(dated, say("first reply"))
	P.record(dated, { type = "user", message = { content = "go" } })
	P.record(dated, say("second reply"))
	P.record(dated, { type = "user", message = { content = "go" } })
	P.record(dated, say("third reply"))
	P.record(dated, { type = "user", message = { content = "queued" } })
	P.record(dated, { type = "user", message = { content = "queued" } })
	P.record(dated, { type = "user", isCompactSummary = true, message = { content = "## Next step\nplan\n" } })
	equal(#dated.responses, 3, "one response a turn")
	equal(dated.responses[1].text, "first reply", "only a turn's last text")
	equal(#dated.prompts, 4, "the same words after a reply count, a record repeated at once doesn't")
	equal(#P.new_state().responses, 0, "no responses yet")
	P.record(dated, say(string.rep("é", 3000)))
	equal(P.width(dated.responses[#dated.responses].text), 3000, "long responses kept whole")

	-- Boxes fold on a click on their top line, and stay in place.
	local tested = P.new_state()
	tested.tests[1] = { command = "npm test", ok = true }
	tested.turn = P.new_turn(100, 1)
	tested.turn.ms, tested.turn.edits, tested.turn.errors, tested.turn.agents = 157000, 4, 1, 1
	local open = P.info_lines(tested, 60, { now = 400, show = "tests" })
	has(plain(open), "✓ last turn 2m37s", "the receipt's title")
	has(plain(open), "1 agent  4 edits  1 error", "what the turn did")
	has(plain(open), "npm test", "the tests, listed")
	hasnt(plain(open), "OPEN", "no box with nothing open")
	hasnt(plain(open), "GATE", "no gate before a check")
	equal(P.width(open[1]), 60, "a box fills the width")
	local closed = P.info_lines(tested, 60, { now = 400, folded = { Receipt = true }, show = "tests" })
	has(plain(closed), "╶ ▸ ✓ last turn 2m37s", "a folded box is one line")
	hasnt(plain(closed), "npm test", "and hides its body")
	local receipt_line
	for line, action in pairs(closed.actions) do
		if action.name == "Receipt" then
			receipt_line = line
		end
	end
	equal(closed.actions[receipt_line].kind, "fold", "the top line folds")
	local layout_fold = { tabs = {}, hits = {}, pinned = 0, actions = closed.actions, scroll = 0 }
	equal(P.hit(layout_fold, 1, receipt_line + 2).name, "Receipt", "a click lands on the top line")
	equal(#closed.sections, 2, "Info's boxes")
	has(P.info_lines(tested, 60, { now = 400, focus = "Receipt" })[receipt_line], "\27[7m", "highlighted title")
	local shows = P.info_lines(tested, 60, { now = 400 })
	local shows_line
	for line, action in pairs(shows.actions) do
		if action.ranges then
			shows_line = line
		end
	end
	local show_layout = { tabs = {}, hits = {}, pinned = 0, actions = shows.actions, scroll = 0 }
	equal(P.hit(show_layout, 3, shows_line + 2).what, "tests", "a click on the tests opens them")
	equal(P.hit(show_layout, 1, shows_line + 2), nil, "the border isn't")
	has(plain(P.info_lines(tested, 30, { now = 400 })), "▾ ✓ last turn", "narrow: a heading, no box")
	hasnt(plain(P.info_lines(tested, 30, { now = 400 })), "╭", "no frame when narrow")
	tested.turn.ms = nil
	local running = plain(P.info_lines(tested, 60, { now = 130 }))
	has(running, " turn 30s", "a running turn's clock")
	has(running, "● running", "running, in the main box")
	equal(P.info_lines(tested, 60, { now = 130 }).ticking, true, "the clock ticks")

	-- The gate: a cell a check, the verdicts, the families and their checks.
	local gated = P.new_state()
	P.gate_check(gated.gate, { decision = "accept", source = "config", reasonType = "classifier" }, "Bash", { command = "npm test" })
	P.gate_check(gated.gate, { decision = "accept", source = "config" }, "Read", { file_path = "/r/a.lua" })
	P.gate_check(gated.gate, { decision = "accept", source = "user_temporary" }, "WebFetch", { url = "https://a.example" })
	P.gate_check(gated.gate, { decision = "reject", source = "user_reject" }, "Bash", { command = "curl -H 'Authorization: Bearer abc' x" })
	P.gate_check(gated.gate, { decision = "accept", source = "config" }, "Read", { file_path = "/r/b.lua" }, true)
	local gate = plain(P.info_lines(gated, 60, { gate = "shell" }))
	has(gate, "GATE · permissions", "the gate box")
	has(gate, "5 checks", "its total")
	has(gate, "⣿⣿⣿✗⣿", "a dotted cell a check, denied as ✗")
	has(gate, "■ 2 allowed  ■ 1 classifier  ■ 1 you  ✗ 1 denied", "verdicts")
	has(gate, "f: file 2  s: shell 2  o: other 1", "families")
	has(gate, "✗ Bash curl -H 'Authorization: Bearer ••• x", "a family's checks, credentials masked")
	hasnt(gate, "Read /r/a.lua", "only the family open")
	equal(P.mask("TOKEN=abc123 run --password hunter2 ok"), "TOKEN=••• run --password ••• ok", "masked values")
	equal(P.mask("git push origin main"), "git push origin main", "nothing to mask")

	-- Subagents: lanes on one time axis, a click opening one.
	local agent = P.new_agent("a1")
	local stamp = function(s) return string.format("2026-11-17T10:00:%02dZ", s) end
	P.agent_record(agent, { type = "assistant", timestamp = stamp(0), message = { usage = { input_tokens = 12000 }, content = {
		{ type = "tool_use", id = "x1", name = "Read", input = { file_path = "/r/a.lua" } } } } }, gated.gate)
	P.agent_record(agent, { type = "user", timestamp = stamp(5), permissionDecision = { decision = "accept", source = "config" },
		message = { content = { { type = "tool_result", tool_use_id = "x1", content = "ok" } } } }, gated.gate)
	P.agent_record(agent, { type = "assistant", timestamp = stamp(42), message = { content = { { type = "text", text = "All good." } } } }, gated.gate)
	agent.description, agent.type, agent.finished = "Review the parser", "Explore", true
	equal(agent.steps, 2, "an agent's steps")
	equal(gated.gate.checks[#gated.gate.checks].sub, true, "an agent's check, as a subagent's")
	local other = P.new_agent("a2")
	other.description, other.start, other.last = "Map the hooks", P.epoch(stamp(30)), P.epoch(stamp(40))
	local lanes = P.info_lines(P.new_state(), 60, { now = P.epoch(stamp(50)), agents = { agent, other }, open_agents = { a1 = true } })
	local shown = plain(lanes)
	has(shown, "AGENTS · 1 running", "running agents")
	has(shown, "2 total", "all agents")
	has(shown, "✓ 1: Review the", "a finished lane")
	equal(shown:find("2: Map the", 1, true) < shown:find("1: Review the", 1, true), true, "newest first")
	has(shown, "● 2: Map the", "a running lane's mark")
	has(shown, "0:42", "its time")
	has(shown, "0:20", "a running agent's clock")
	has(shown, "Explore", "an open lane's type")
	has(shown, "ctx 12k", "its context")
	has(shown, "› Read /r/a.lua", "its tool calls")
	has(shown, "All good.", "its answer")
	local team = P.new_agent("t1")
	team.description, team.start, team.last = "Translate listings", P.epoch(stamp(0)) - 900, P.epoch(stamp(0)) - 800
	local with_team = plain(P.info_lines(P.new_state(), 60, { now = P.epoch(stamp(50)), agents = { team, agent, other } }))
	has(with_team, "AGENTS · 1 running", "an agent quiet for 5 minutes isn't running")
	has(with_team, "○ 1: Translate", "it shows as idle")
	has(with_team, "1:40", "its clock stops at its last activity")
	local lane_actions = 0
	for _, a in pairs(lanes.actions) do
		if a.kind == "agent" then
			lane_actions = lane_actions + 1
		end
	end
	equal(lane_actions, 2, "a click a lane")

	-- Processes: Claude's shells, named by the call that started them.
	local ps = table.concat({
		"  100     1 01:00:00 /bin/zsh",
		"  200   100    10:00 /Applications/Claude",
		"  300   200    02:05 /bin/zsh",
		"  301   300    02:05 npm",
		"  310   200    00:30 /bin/zsh",
		"  311   310    00:30 tail",
		"  320   200    00:05 /bin/zsh",
		"  330   200    02:00 caffeinate",
		"  321   320    00:05 sleep",
		"  400     1    05:00 /bin/zsh",
	}, "\n")
	equal(P.etime("1-02:03:04"), 93784, "ps elapsed time")
	local monitors = { { description = "Watch the build", at = 1000 - 31, expires = 2000 }, { description = "Expired watch", at = 1000 - 125, expires = 900 } }
	local procs = P.processes(200, ps, monitors, 1000)
	equal(#procs, 3, "only Claude's shells")
	equal(procs[1].name, "waiting", "a shell that only sleeps")
	equal(procs[2].name .. " " .. procs[2].kind, "Watch the build monitor", "a monitor, by when it started")
	equal(procs[3].name .. " " .. procs[3].kind, "npm shell", "a program; an expired monitor doesn't name it")
	local watched = P.new_state()
	P.record(watched, { type = "assistant", timestamp = "1970-01-01T00:10:00Z", message = { content = { { type = "tool_use", id = "m1", name = "Monitor", input = { description = "Watch the build" } } } } })
	P.record(watched, { type = "user", timestamp = "1970-01-01T00:10:01Z", toolUseResult = { timeoutMs = 60000 }, message = { content = { { type = "tool_result", tool_use_id = "m1", content = "started" } } } })
	equal(#watched.monitors, 1, "a monitor from the transcript")
	equal(watched.monitors[1].description .. " " .. watched.monitors[1].at .. " " .. watched.monitors[1].expires, "Watch the build 601 661", "its description, start and timeout")
	-- Background tasks: started by Bash or Monitor, ended by a notification.
	local bg = P.new_state()
	local at = function(sec, r) r.timestamp = string.format("1970-01-01T00:%02d:00Z", sec); P.record(bg, r) end
	at(1, { type = "assistant", message = { content = { { type = "tool_use", id = "b1", name = "Bash", input = { command = "TOKEN=abc ./batch.sh all", run_in_background = true } } } } })
	at(1, { type = "user", toolUseResult = { backgroundTaskId = "bt1" }, message = { content = { { type = "tool_result", tool_use_id = "b1", content = "started" } } } })
	at(2, { type = "assistant", message = { content = { { type = "tool_use", id = "m2", name = "Monitor", input = { description = "Watch the batch" } } } } })
	at(2, { type = "user", toolUseResult = { taskId = "mt2", timeoutMs = 600000 }, message = { content = { { type = "tool_result", tool_use_id = "m2", content = "started" } } } })
	at(3, { type = "assistant", message = { content = { { type = "tool_use", id = "b3", name = "Bash", input = { command = "npm test", run_in_background = true } } } } })
	at(3, { type = "user", toolUseResult = { backgroundTaskId = "bt3" }, message = { content = { { type = "tool_result", tool_use_id = "b3", content = "started" } } } })
	at(4, { type = "user", message = { content = "<system-reminder>\n<task-notification>\n<task-id>bt3</task-id>\n<status>completed</status>\n</task-notification>" } })
	local running_bg = P.running_tasks(bg, 300)
	equal(#running_bg, 2, "an ended task isn't running")
	equal(running_bg[1].name, "Watch the batch", "a monitor by its description, newest first")
	equal(running_bg[2].name, "TOKEN=••• ./batch.sh all", "a shell by its command, masked")
	equal(#P.running_tasks(bg, 120 + 601), 1, "a monitor ends at its timeout")
	equal(#P.running_tasks(bg, 300, { { age = 300 - 120 } }), 1, "only tasks with a live shell")
	equal(P.running_tasks(bg, 300, { { age = 300 - 60 } })[1].name, "TOKEN=••• ./batch.sh all", "matched by start time")
	local proc_view = P.info_lines(P.new_state(), 60, { now = 1000, processes = procs })
	has(plain(proc_view), "PROCESSES · 3 running", "the processes box")
	has(plain(proc_view), "● npm  shell", "a shell by its program")
	has(plain(proc_view), "● Watch the build  monitor", "a monitor by its description")
	local coloured = table.concat(proc_view, "\n")
	has(coloured, "\27[38;5;75m●", "a monitor's mark in blue")
	has(coloured, "\27[38;5;114mshell", "a shell's tag in green")
	has(plain(proc_view), "2:05", "how long it has run")
	equal(proc_view.ticking, true, "clocks tick while processes run")
	hasnt(plain(P.info_lines(P.new_state(), 60, { processes = {} })), "PROCESSES", "no box without processes")

	-- The log: events as they happen, as many as fit.
	local logged = P.new_state()
	local at = function(sec, r) r.timestamp = string.format("2026-11-17T10:00:%02dZ", sec); P.record(logged, r) end
	at(1, { type = "user", message = { content = "Fix the cart" } })
	at(2, { type = "assistant", message = { content = { { type = "tool_use", id = "g1", name = "Agent", input = { description = "Map the cart" } } } } })
	at(3, { type = "user", message = { content = { { type = "tool_result", tool_use_id = "g1", content = "done" } } } })
	at(4, { type = "assistant", message = { content = { { type = "tool_use", id = "w1", name = "Write", input = { file_path = "/w/a.lua" } } } } })
	at(5, { type = "user", permissionDecision = { decision = "reject", source = "user_reject" }, message = { content = { { type = "tool_result", tool_use_id = "w1", content = "no", is_error = true } } } })
	equal(#logged.log, 4, "prompt, agent start and end, denial")
	local log_view = plain(P.info_lines(logged, 60, { rows = 40 }))
	has(log_view, "LOG", "the log box")
	has(log_view, "main    › Fix the cart", "a prompt")
	has(log_view, "agent   started · Map the cart", "an agent's start")
	has(log_view, "agent   done · Map the cart", "and end")
	has(log_view, "gate    ✗ Write /w/a.lua", "a denial")
	local short = plain(P.info_lines(logged, 60, { rows = 1 }))
	hasnt(short, "Fix the cart", "only the latest when there's no room")
	has(short, "✗ Write", "at least 3 events")

	-- The advisor's consults.
	local advised = P.new_state()
	advised.consults = { { id = "s1", at = 100, done = 127 } }
	local advice = plain(P.info_lines(advised, 60, { now = 134 }))
	has(advice, "ADVISOR · on call", "the advisor box")
	has(advice, "consults 1", "consults")
	has(advice, "last 7s ago · took 27s", "the last consult")
	hasnt(plain(P.info_lines(P.new_state(), 60)), "ADVISOR", "no box without consults")

	local folds = dir .. "fold-test/"
	real.exec({ "mkdir", "-p", folds })
	local S = dofile(dir .. "settings.lua")
	local ok_fold, err_fold = pcall(function()
		equal(next(S.folded(folds)), nil, "nothing folded at first")
		S.set_auto_show(folds, false)
		S.set_folded(folds, "Tests", true)
		S.set_folded(folds, "Open", true)
		equal(S.folded(folds).Tests, true, "fold saved")
		S.set_folded(folds, "Tests", false)
		equal(S.folded(folds).Tests, nil, "unfold saved")
		equal(S.folded(folds).Open, true, "other folds kept")
		equal(S.auto_show(folds), false, "other settings kept")
	end)
	real.exec({ "rm", "-rf", folds })
	if not ok_fold then
		error(err_fold, 0)
	end
end)
if not ok2 then
	error(err2, 0)
end
-- Rex View: what Claude's last replies mention.
do
	local V = dofile(dir .. "mentions.lua")
	local function rec(t) return rex.json.encode(t) end
	local function said(text) return rec({ type = "assistant", message = { content = { { type = "text", text = text } } } }) end
	local function asked(text) return rec({ type = "user", message = { content = text } }) end
	local result = rec({ type = "user", message = { content = { { type = "tool_result", content = "x" } } } })
	local lines = { asked("one"), said("old.md"), asked("two"), said("first part"), result, said("second part"), asked("three"), said("newest") }
	local turns = V.turns(lines, 2)
	equal(#turns, 2, "only the last n turns")
	equal(turns[1], "newest", "newest first")
	equal(turns[2], "second part", "only the final message, and a tool result doesn't end a turn")
	equal(#V.turns(lines, 9), 3, "fewer turns than asked")
	equal(#V.turns({ said("still answering") }, 3), 1, "a turn without its prompt in the tail")

	local p, l = V.path_token("(`src/app.lua:12`),")
	equal(p, "src/app.lua", "path out of punctuation")
	equal(l, "12", "its line")
	equal(select(2, V.path_token("a.lua:3:7")), "3", "line and column")
	equal(V.path_token("hello"), nil, "a plain word")
	equal(V.path_token("`src/ui/View.tsx`."), "src/ui/View.tsx", "a code span before a full stop")
	equal(V.path_token("https://x.io/a.md"), nil, "a URL isn't a path")

	local files = { ["/r/src/app.lua"] = "file", ["/r/shot.png"] = "file", ["/r/docs"] = "dir", ["/abs/notes.txt"] = "file" }
	local function kind(path) return files[path] end
	local rows = V.find({
		"See `src/app.lua:12` and ![shot](shot.png), docs/ and /abs/notes.txt. Also missing.md.",
		"PR https://github.com/acme/web/pull/7, ticket PROJ-12 and acme/web#45; again src/app.lua:12",
	}, "/r", V.rules_for({ ["/"] = {
		["%u+%-%d+"] = "https://acme.atlassian.net/browse/",
		["acme/web#(%d+)"] = "https://github.com/acme/web/pull/",
		["bad[pattern"] = "https://x.io/",
		["PROJ"] = "not a link",
	} }, "/r"), kind)
	local by = {}
	for i, r in ipairs(rows) do by[r.target] = { i = i, row = r } end
	equal(by["/r/src/app.lua"].row.kind, "text", "a text file")
	equal(by["/r/src/app.lua"].row.line, "12", "with its line")
	equal(by["/r/src/app.lua"].row.label, "src/app.lua:12", "shown relative to Claude's folder")
	equal(by["/r/shot.png"].row.kind, "image", "an image from a Markdown link")
	equal(by["/abs/notes.txt"] ~= nil, true, "an absolute path")
	equal(by["/r/docs"], nil, "folders aren't listed")
	equal(by["https://github.com/acme/web/pull/7"].row.kind, "link", "a URL")
	equal(by["https://acme.atlassian.net/browse/PROJ-12"].row.label, "PROJ-12", "a pattern match")
	equal(by["https://acme.atlassian.net/browse/PROJ-12"].row.note, "acme.atlassian.net", "the basis' host")
	equal(by["https://github.com/acme/web/pull/45"] ~= nil, true, "a capture goes after the basis")
	equal(by["https://x.io/"], nil, "a pattern that doesn't compile")
	equal(by["/r/src/app.lua"].i < by["https://github.com/acme/web/pull/7"].i, true, "newest turn first")
	local count = 0
	for _, r in ipairs(rows) do if r.target == "/r/src/app.lua" then count = count + 1 end end
	equal(count, 1, "listed once")
	equal(#V.find({ "PROJ-1" }, "/r", nil, kind), 0, "no patterns by default")
	local jira = V.rules_for({ ["/"] = { ["%W(TF%-%d+)"] = "https://j.example/browse/", ["%W#(%d+)"] = "https://g.example/pull/" } }, "/r")
	local keyed = {}
	for _, r in ipairs(V.find({ "TF-12 first, UTF-8 isn't, (TF-3) is, see #5 but not repo#6" }, "/r", jira, kind)) do keyed[r.target] = r.label end
	equal(keyed["https://j.example/browse/TF-12"], "TF-12", "a key at the start, with a clean label")
	equal(keyed["https://j.example/browse/TF-3"], "TF-3", "a key in brackets")
	equal(keyed["https://j.example/browse/TF-8"], nil, "not inside a word")
	equal(keyed["https://g.example/pull/5"], "#5", "a bare number")
	equal(keyed["https://g.example/pull/6"], nil, "not after a repository name")

	-- Link patterns locked to directories.
	local saved = {
		["/"] = { ["%u+%-%d+"] = "https://all.example/browse/", ["#(%d+)"] = "https://all.example/pr/" },
		["/w/acme/"] = { ["acme#(%d+)"] = "https://github.com/acme/pull/" },
		["/w/acme/mobile"] = { ["%u+%-%d+"] = "https://mobile.example/browse/" },
		["/w/acme-old"] = { ["old#(%d+)"] = "https://old.example/" },
		["%d+x"] = "https://flat.example/",
	}
	local function patterns_of(rules)
		local out = {}
		for _, r in ipairs(rules) do out[#out + 1] = r.pattern .. "=" .. r.basis:match("//([^/]+)") end
		return table.concat(out, " ")
	end
	equal(patterns_of(V.rules_for(saved, "/w/acme/mobile/src")),
		"%u+%-%d+=mobile.example acme#(%d+)=github.com #(%d+)=all.example %d+x=flat.example",
		"nearest first, a nearer pattern wins, and the flat one counts for every project")
	equal(patterns_of(V.rules_for(saved, "/w/acme")), "acme#(%d+)=github.com #(%d+)=all.example %d+x=flat.example %u+%-%d+=all.example", "a trailing slash in the key")
	equal(patterns_of(V.rules_for(saved, "/w/acme-older")), "#(%d+)=all.example %d+x=flat.example %u+%-%d+=all.example", "whole path parts only")
	equal(patterns_of(V.rules_for(saved, nil)), "#(%d+)=all.example %d+x=flat.example %u+%-%d+=all.example", "no directory: every project's")
	equal(#V.rules_for(nil, "/w"), 0, "no patterns")
	equal(V.dir_key("/w/x//"), "/w/x", "trailing slashes")
	equal(V.dir_key("/"), "/", "the root")

	-- The Artifacts tab: categories, newest first, each row once.
	local function row(kind, target, line)
		return { kind = kind, label = target, target = target, line = line }
	end
	equal(V.category(row("text", "/r/notes.md")), "Documents", "Markdown")
	equal(V.category(row("image", "/r/a.PNG")), "Documents", "an image")
	equal(V.category(row("text", "/r/app.lua")), "Other", "source code")
	equal(V.category(row("link", "https://github.com/o/r/pull/12/files")), "PRs", "a PR")
	equal(V.category(row("link", "https://gitlab.com/o/r/-/merge_requests/3")), "PRs", "a merge request")
	equal(V.category(row("link", "https://acme.atlassian.net/browse/SHOP-12")), "Jira", "a Jira issue")
	equal(V.category(row("link", "https://a.example/x")), "URLs", "another link")
	local groups, total = V.group({
		{ row("link", "https://a.example/x"), row("text", "/r/app.lua", "3") },
		{ row("text", "/r/notes.md"), row("link", "https://a.example/x"), row("link", "https://acme.atlassian.net/browse/SHOP-12") },
	})
	local names = {}
	for _, g in ipairs(groups) do names[#names + 1] = g.name .. "=" .. #g.rows end
	equal(table.concat(names, " "), "Documents=1 Jira=1 URLs=1 Other=1", "empty categories left out, in order")
	equal(total, 4, "a row mentioned twice counts once")
	equal(#V.group({}), 0, "nothing found")
	local view = P.artifacts_view(groups, 40, {}, nil, nil)
	local shown = plain(view.lines)
	has(plain(view.pinned), "Search Panel", "the Search Panel link, pinned")
	equal(view.hits[1][1].action.kind, "view_panel", "it opens the Search Panel")
	has(shown, "╭ ▤ Documents", "a category box, with its icon")
	hasnt(shown, "PRs", "no empty category")
	has(shown, "/r/app.lua  text", "a file row")
	local kinds = {}
	for _, a in pairs(view.actions) do kinds[a.kind] = (kinds[a.kind] or 0) + 1 end
	equal(kinds.mention, 4, "each row opens")
	equal(kinds.fold, 4, "each heading folds")
	equal(#view.sections, 4, "a section a category")
	hasnt(plain(P.artifacts_view(groups, 40, { Documents = true }).lines), "notes.md", "folded")
	has(plain(P.artifacts_view({}, 40, {}).lines), "Nothing in Claude's replies yet.", "nothing found")
	has(plain(P.artifacts_view({}, 40, {}, nil, "boom").pinned), "boom", "a notice under the link")
	local tsv = V.tsv({ { name = "Other", rows = { { kind = "text", label = "a\tb", target = "/r/a", line = "3" } } } })
	equal(select(2, tsv:gsub("\t", "")), 3, "tabs only between fields")
	has(tsv, "Other", "the category as the note")
	-- PRs: links into one PR put together, comments as "# N".
	local function ref(url)
		local r = V.pr_ref(url)
		return r and (r.name .. "|" .. (r.sub or "") .. "|" .. r.target) or "nil"
	end
	equal(ref("https://github.com/acme/shop/pull/42"), "acme/shop#42||https://github.com/acme/shop/pull/42", "a PR")
	equal(ref("https://github.com/acme/shop/pull/42#issuecomment-123"), "acme/shop#42|# 123|https://github.com/acme/shop/pull/42", "a comment")
	equal(ref("https://github.com/acme/shop/pull/42/files#r456"), "acme/shop#42|files|https://github.com/acme/shop/pull/42", "its files")
	equal(ref("https://github.com/acme/shop/pull/42/files#discussion_r789"), "acme/shop#42|# 789|https://github.com/acme/shop/pull/42", "a review comment")
	equal(ref("https://github.com/acme/shop/pull/42#pullrequestreview-5"), "acme/shop#42|# 5|https://github.com/acme/shop/pull/42", "a review")
	equal(ref("https://github.com/acme/shop/pull/42/commits/abcdef0123"), "acme/shop#42|commit abcdef0|https://github.com/acme/shop/pull/42", "a commit")
	equal(ref("https://gitlab.com/g/sub/app/-/merge_requests/3#note_9"), "g/sub/app#3|# 9|https://gitlab.com/g/sub/app/-/merge_requests/3", "a merge request note")
	equal(ref("https://a.example/x"), "nil", "not a PR")
	local pr_groups, pr_total = V.group({
		{ row("link", "https://github.com/acme/shop/pull/42#issuecomment-123"), row("link", "https://github.com/acme/api/pull/7") },
		{ row("link", "https://github.com/acme/shop/pull/42"), row("link", "https://github.com/acme/shop/pull/42/files"),
			row("link", "https://github.com/acme/web/pull/1#issuecomment-8") },
	})
	local prs = pr_groups[1].rows
	equal(pr_groups[1].name .. "=" .. #prs .. " " .. pr_total, "PRs=3 3", "one row a PR, counted as one")
	equal(prs[1].name .. " " .. #prs[1].rows .. " " .. tostring(prs[1].direct), "acme/shop#42 2 true", "a PR's links")
	local pr_view = plain(P.artifacts_view(pr_groups, 60, {}, nil, nil, { ["https://github.com/acme/shop/pull/42"] = "Add rate-limit guard" }).lines)
	has(pr_view, "#42 Add rate-limit guard", "a PR's number before its title")
	has(pr_view, "╭ ⇄ PRs", "the PRs box")
	has(pr_view, "Add rate-limit guard", "a PR by its title")
	has(pr_view, "  # 123", "a comment under its PR")
	has(pr_view, "  files", "the files under their PR")
	has(pr_view, "│ acme/api#7  ", "a PR with no title yet, and one link")
	has(pr_view, "acme/web#1  # 8", "a PR's only link, on its row")
	hasnt(pr_view, "guard  acme/shop#42", "no repository and number beside a title")
	local pr_actions = {}
	for _, a in pairs(P.artifacts_view(pr_groups, 60, {}).actions) do
		if a.kind == "mention" then pr_actions[#pr_actions + 1] = a.row.target end
	end
	table.sort(pr_actions)
	equal(table.concat(pr_actions, " "), table.concat({
		"https://github.com/acme/api/pull/7", "https://github.com/acme/shop/pull/42",
		"https://github.com/acme/shop/pull/42#issuecomment-123", "https://github.com/acme/shop/pull/42/files",
		"https://github.com/acme/web/pull/1#issuecomment-8" }, " "), "each row opens its own link")
	-- Each category shows its newest 10, then a link to the rest.
	local many = {}
	for i = 1, 13 do
		many[i] = { kind = "link", label = "https://a.example/" .. i, target = "https://a.example/" .. i }
	end
	local capped = P.artifacts_view(V.group({ many }), 60, {})
	has(plain(capped.lines), "a.example/10", "the 10th row")
	hasnt(plain(capped.lines), "a.example/11", "not the 11th")
	has(plain(capped.lines), "+3 more · Search Panel", "how many more")
	local more_kind
	for _, a in pairs(capped.actions) do
		if a.kind == "view_panel" then
			more_kind = a.kind
		end
	end
	equal(more_kind, "view_panel", "the rest open in the Search Panel")
	has(plain(capped.lines), "13", "the count stays the total")

	-- Jira titles, as the replies wrote them.
	equal(V.jira_title("Fixed in SHOP-12 (Cart rounding). Next.", "SHOP-12"), "Cart rounding", "in brackets")
	equal(V.jira_title("- **SHOP-12**: Cart rounding fix.", "SHOP-12"), "Cart rounding fix", "after a colon")
	equal(V.jira_title("See [SHOP-12 Cart rounding](https://a.atlassian.net/browse/SHOP-12)", "SHOP-12"), "Cart rounding", "a link's text")
	equal(V.jira_title("| SHOP-12 | Cart rounding | Done |", "SHOP-12"), "Cart rounding", "a table cell")
	equal(V.jira_title("SHOP-12 is done", "SHOP-12"), nil, "no title")
	local jira_rows = V.find({ "Done: SHOP-12 (Cart rounding)" }, "/w", V.rules_for({ ["/w"] = { ["(SHOP%-%d+)"] = "https://a.atlassian.net/browse/" } }, "/w"))
	equal(jira_rows[1].title, "Cart rounding", "a found key's title")
	local jira_groups = V.group({ { { kind = "link", label = "SHOP-12", target = "https://a.atlassian.net/browse/SHOP-12" } }, jira_rows })
	equal(jira_groups[1].rows[1].title, "Cart rounding", "an older reply's title fills a newer mention's")
	has(plain(P.artifacts_view(jira_groups, 60, {}).lines), "SHOP-12 Cart rounding", "the key, then the title")
	local pr_tsv = V.tsv(pr_groups)
	has(pr_tsv, "acme/shop#42 # 123", "a comment in the Search Panel")
	has(pr_tsv, "⇄\27[0m acme/shop#42", "a category's icon on each row")
	equal(select(2, pr_tsv:gsub("\n", "")), 6, "the Search Panel: a row a PR and a row a link into it")
	-- Background tasks: commands run without blocking, inside a task only.
	equal(P.run({ "/bin/echo", "hi" }).stdout, "hi\n", "a command outside a task blocks")
	local got, steps = nil, 0
	equal(P.spawn("echo", function() got = P.run({ "/bin/sh", "-c", "sleep 0.3; echo later" }) end), true, "a task starts")
	equal(P.spawn("echo", function() end), false, "one task a name")
	local start, longest = os.clock(), 0
	repeat
		local t = os.clock()
		local ended = P.step_tasks()
		longest = math.max(longest, os.clock() - t)
		steps = steps + 1
		rex.sleep(0.05)
	until ended
	equal(longest < 0.05, true, "a step doesn't wait for the command")
	equal(got and got.stdout, "later\n", "the command's result, once it ends")
	equal(steps > 2, true, "stepped while the command ran")
	local slow = "unset"
	P.spawn("slow", function() slow = P.run({ "/bin/sleep", "5" }, 0.2) end)
	start = os.clock()
	while not P.step_tasks() do rex.sleep(0.05) end
	equal(slow, nil, "a command that runs too long is stopped")
	equal(os.clock() - start < 1, true, "and doesn't hold the task")
	local work = 0
	P.spawn("work", function() for _ = 1, 3 do work = work + 1; coroutine.yield() end end)
	P.step_tasks()
	equal(work, 3, "a task that only works runs on within a step")
	equal(V.kind("/") , "dir", "a real folder")
	equal(V.kind(dir .. "test.lua"), "file", "a real file")
	equal(V.kind(dir .. "no-such-file"), nil, "a missing file")
end
return "cc-sidecar: all tests passed"
