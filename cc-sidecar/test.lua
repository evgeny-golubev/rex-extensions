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
	equal(split.ratio, 0.8, "ratio")
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
	equal(resized[1].ratio, 0.8, "resized ratio")

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

	-- A pane whose login shell execs Claude is found by the recheck, once.
	fire()
	equal(#timers, 0, "rechecks before")
	processes["block:3"] = { foreground = { argv0 = "claude", cwd = "/src/app" } }
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
	local context = plain(P.log_lines(state, 60))
	has(context, "Add tabs to the panel", "prompt")
	has(context, "/review high", "slash command")
	has(context, "Also add a hint", "queued prompt")
	equal(#state.prompts, 3, "prompts, without meta, notices, a prompt recorded twice, or subagents")
	has(context, "Which tabs?", "question")
	has(context, "→ Diff and Context", "answer")
	has(context, "keep Diff first", "answer note")
	has(context, "Plan approved: Tabbed panel", "plan")
	has(context, "Rejected Bash: rm -rf build", "rejected action")
	has(context, "keep build", "what the user said")
	has(info, "? Ship it now?", "waiting question")
	has(info, "? Should I also add a third tab?", "question in the last reply")
	has(info, "○ Draw the tabs", "open task")
	hasnt(info, "Write the parser", "completed task")
	has(info, "▸ Update the README", "todo in progress")
	hasnt(info, "Decisions", "Decisions moved to Log")
	hasnt(info, "Requests", "Requests moved to Log")
	hasnt(info, "Current state", "the summary moved to Log")
	has(context, "Current state", "summary section")
	local many = P.new_state()
	for i = 1, 7 do
		many.prompts[i] = { text = "request " .. i }
	end
	for i = 8, 52 do
		many.prompts[i] = { text = "request " .. i }
	end
	local paged = P.log_lines(many, 60)
	local recent = plain(paged)
	has(recent, "Requests 52", "requests count")
	has(recent, "\n\n← Next 1/18 Previous →\n\n", "pager, with a blank row on each side")
	has(recent, "request 52", "newest request")
	has(recent, "request 50", "third newest request")
	hasnt(recent, "request 49", "next page's request")
	equal(recent:find("request 50", 1, true) < recent:find("1/18", 1, true), true, "pager after the entries")
	equal(recent:find("request 52", 1, true) < recent:find("request 51", 1, true), true, "newest first")
	local second = plain(P.log_lines(many, 60, nil, nil, { Requests = 2 }))
	has(second, "← Next 2/18 Previous →", "second page")
	has(second, "request 49", "second page's first request")
	has(second, "request 47", "second page's last request")
	hasnt(second, "request 50", "first page's request")
	hasnt(second, "request 46", "third page's request")
	local last = plain(P.log_lines(many, 60, nil, nil, { Requests = 99 }))
	has(last, "18/18", "a page past the end shows the last")
	has(last, "request 1\n", "the oldest request")
	hasnt(last, "request 2\n", "the page before the last")
	hasnt(plain(P.log_lines(state, 60)), "/1 ", "no pager on a single page")

	-- The pager's sides are clickable only where there's a page to go to.
	local function pager_line(lines)
		for line, action in pairs(lines.actions) do
			if action.ranges then
				return line
			end
		end
	end
	local function click(lines, x)
		local layout = { tabs = {}, hits = {}, pinned = 0, actions = lines.actions, scroll = 0 }
		return P.hit(layout, x, pager_line(lines) + 2)
	end
	equal(click(paged, 1), nil, "no later page on the first")
	equal(click(paged, 21).page, 2, "Previous goes to the earlier entries")
	equal(click(paged, 21).name, "Requests", "the page's section")
	equal(click(paged, 8), nil, "the page number isn't a button")
	local middle = P.log_lines(many, 60, nil, nil, { Requests = 3 })
	equal(click(middle, 1).page, 2, "Next goes to the later entries")
	equal(click(middle, 6).page, 2, "the end of Next")
	equal(click(middle, 7), nil, "just past Next")
	equal(click(P.log_lines(many, 60, nil, nil, { Requests = 18 }), 21), nil, "no earlier page on the last")
	has(context, "parser done", "summary text")
	hasnt(context, "old", "summary sections that aren't about where work stands")
	hasnt(context, "If you need", "Claude Code's note after the summary")

	local this_turn = plain({ P.turn_patch(state, "/src/app/panel.lua", "panel.lua") })
	has(this_turn, "panel.lua", "edit in the turn")
	equal(state.turn.files["/src/app/gone.lua"], nil, "failed write")

	-- A prompt after the reply answers its questions.
	P.feed(state, rex.json.encode({ type = "user", message = { content = "No third tab" } }) .. "\n")
	hasnt(plain(P.info_lines(state, 60)), "third tab?", "answered reply question")

	local activity = plain(P.info_lines(state, 60))
	hasnt(activity, "Files Claude edited", "no edited files section")
	has(activity, "✗ rex do test.lua", "failed test")
	hasnt(activity, "cat test.lua", "a command that only names a test file")
	has(activity, "exit 1: boom: parser", "failure")
	has(activity, "2m", "Claude time")
	has(activity, "41k tokens", "context")

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
	has(patch, "--- a/a.lua\n+++ b/a.lua\n", "patch names the file")
	has(patch, "@@ -3,2 +3,2 @@\n k\n-a\n+b\n+c\n", "first hunk")
	has(patch, "@@ -9,1 +9,0 @@\n-z\n", "second hunk")
	has(P.turn_patch(turn, "/src/app/new.lua", "new.lua"), "@@ -0,0 +1,2 @@\n+one\n+two\n", "new file's hunk")

	-- The Changes view: pinned header, grouped list and clickable rows.
	local v = { title = "feature/x", scope = "Uncommitted", scopes = P.scopes(true), data = data }
	data.added, data.removed = 7, 2
	local built = P.changes_view(v, 40)
	equal(#built.pinned, 3, "pinned lines")
	has(plain({ built.pinned[1] }), "feature/x", "branch")
	has(plain({ built.pinned[1] }), "+7 −2", "totals")
	equal(P.width(built.pinned[1]), 40, "header fills the width")
	has(plain({ built.pinned[2] }), "Last Turn", "scope")
	has(plain(built.lines), "Staged (2)", "staged heading")
	has(plain(built.lines), "Unstaged (3)", "unstaged heading")
	has(plain(built.lines), "A x.md  docs", "row with its folder")
	equal(built.rows[1].row.diff, "staged", "first row")
	equal(built.actions[built.rows[1].line].kind, "open", "row is clickable")
	v.selected = built.rows[1].key
	has(plain(P.changes_view(v, 40).lines), "› ", "selected row")
	equal(table.concat(P.scopes(false), ","), "Last Turn", "scopes without git")

	-- The tree merges the groups and lists folders.
	v.tree, v.selected = true, nil
	local tree = P.changes_view(v, 40)
	has(plain(tree.lines), "Changed (4)", "tree heading")
	has(plain(tree.lines), "▾ docs", "folder")
	equal(#tree.rows, 4, "tree rows")
	equal(tree.rows[1].row.diff, "head", "tree row's diff")
	local deep = P.changes_view({ title = "m", scope = "Branch", scopes = P.scopes(true), tree = true, data = { groups = { { title = "Changed", rows = {
		{ path = "src/cart/a.ts", mark = "M" }, { path = "src/cart/b.ts", mark = "A" }, { path = "src/ui/c.ts", mark = "M" }, { path = "z.ts", mark = "D" },
	} } }, vs = "main" } }, 30)
	local shown_tree = plain(deep.lines)
	has(shown_tree, "vs main", "what the branch compares with")
	local _, cart_count = shown_tree:gsub("▾ cart", "")
	equal(cart_count, 1, "a folder is listed once")
	has(shown_tree, "▾ ui", "sibling folder")
	has(shown_tree, "z.ts", "top-level file")

	-- Narrow panes get the short scope names; the columns follow.
	local narrow, narrow_ranges = P.scope_bar(P.scopes(true), "Branch", 26)
	has(plain({ narrow }), "Local", "short name")
	hasnt(plain({ narrow }), "Uncommitted", "long name")
	equal(narrow_ranges[3].action.scope, "Branch", "last scope")
	local _, wide_ranges = P.scope_bar(P.scopes(true), "Branch", 60)
	equal(wide_ranges[1].from, 1, "first scope's column")
	equal(wide_ranges[2].from, wide_ranges[1].to + 2, "columns leave a space")

	-- Clicks land on what's drawn.
	local _, tab_ranges = P.frame(P.tabs, "Changes", {}, 0, 40, 10, { badges = { Changes = "3" } })
	local layout = { tabs = tab_ranges, hits = built.hits, pinned = 3, actions = built.actions, scroll = 0 }
	equal(P.hit(layout, 2, 1).tab, "Info", "click a tab")
	equal(P.hit(layout, 8, 1).tab, "Changes", "click the other tab")
	equal(P.hit(layout, 2, 2), nil, "click the blank row")
	equal(P.hit(layout, 40, 3).kind, "tree", "click the tree toggle")
	equal(P.hit(layout, 2, 4).scope, "Last Turn", "click a scope")
	equal(P.hit(layout, 2, 5), nil, "click the blank pinned row")
	equal(P.hit(layout, 2, 7).row.diff, "staged", "click a row")
	layout.scroll = 1
	equal(P.hit(layout, 2, 6).row.diff, "staged", "click a row when scrolled")

	-- Usage: hidden without the saved input, and a passed reset counts as unused.
	hasnt(plain(P.info_lines(P.new_state(), 40)), "Usage", "no usage saved")
	local limits = { five_hour = { used_percentage = 58, resets_at = 1300 }, seven_day = { used_percentage = 17, resets_at = 500 } }
	local usage = plain(P.info_lines(P.new_state(), 40, limits, 1000))
	has(usage, "Usage", "usage heading")
	has(usage, "58%", "5-hour percentage")
	has(usage, "Resets in 5m", "time to the reset")
	has(usage, "0%", "a window that has reset")
	equal(usage:find("Session", 1, true) < usage:find("Usage", 1, true), true, "Session before Usage")
	equal(usage:find("Usage", 1, true) < usage:find("Open", 1, true), true, "Usage before Open")

	-- A float from an earlier diff is found by its label.
	local view = { windows = { { window_id = "w", layers = {
		{ layer_id = "t", kind = "tiled", blocks = { { block_id = "me", label = "Diff: tiled" } } },
		{ layer_id = "f", kind = "floating", blocks = { { block_id = "d", label = "Diff: a.lua" } } },
		{ layer_id = "o", kind = "floating", blocks = { { block_id = "o", label = "View: a.lua" } } },
	} } } }
	equal(P.window_of(view, "me").window_id, "w", "window of the pane")
	equal(table.concat(P.old_diffs(view.windows[1]), ","), "f", "earlier diff floats")

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
	has(plain(P.info_lines(levels, 60)), "Reasoning   medium", "reasoning in Activity")
	hasnt(plain(P.info_lines(P.new_state(), 60)), "Reasoning", "no level known")

	-- Log entries carry their local time, newest first.
	equal(P.stamp("2026-11-03T15:46:12.590Z"), os.date("%m-%d %H:%M", 1793720772), "UTC to local")
	equal(P.stamp("2024-02-29T00:00:00Z"), os.date("%m-%d %H:%M", 1709164800), "leap day")
	equal(P.stamp(nil), "", "no timestamp")
	local dated = P.new_state()
	local function at(t, r)
		r.timestamp = "2026-11-03T" .. t .. ":00Z"
		P.record(dated, r)
	end
	local function say(text)
		return { type = "assistant", message = { content = { { type = "text", text = text } } } }
	end
	at("10:00", { type = "user", message = { content = "first go" } })
	at("10:01", say("thinking"))
	at("10:02", say("first reply"))
	at("11:00", { type = "user", message = { content = "go" } })
	at("11:01", say("second reply"))
	at("12:00", { type = "user", message = { content = "go" } })
	at("12:01", say("third reply"))
	at("13:00", { type = "user", message = { content = "queued" } })
	at("13:00", { type = "user", message = { content = "queued" } })
	at("14:00", { type = "user", isCompactSummary = true, message = { content = "## Next step\nOlder plan\n" } })
	at("15:00", { type = "user", isCompactSummary = true, message = { content = "## Next step\nNewer plan\n" } })
	equal(#dated.responses, 3, "one response a turn")
	equal(#dated.prompts, 4, "the same words after a reply count, a record repeated at once doesn't")
	local log = plain(P.log_lines(dated, 60))
	has(log, "≡ Summary from " .. P.stamp("2026-11-03T15:00:00Z"), "summary heading")
	has(plain(P.log_lines(P.new_state(), 60)), "≡ Summary none", "no summary yet")
	has(log, "◈ Decisions none", "decisions heading")
	has(log, "› Requests 4", "requests heading")
	has(log, "‹ Responses 3", "responses heading")
	has(log, "‹ " .. P.stamp("2026-11-03T11:01:00Z") .. ": second reply", "date in front of the entry")
	has(log, "› " .. P.stamp("2026-11-03T13:00:00Z") .. ": queued", "date in front of a request")
	hasnt(log, "thinking", "only a turn's last text")
	has(log, "\nNext step\n  Newer plan", "the latest summary")
	hasnt(log, "Older plan", "earlier summaries")
	equal(log:find("third reply", 1, true) < log:find("first reply", 1, true), true, "newest response first")
	equal(#P.new_state().responses, 0, "no responses yet")
	P.record(dated, say(string.rep("é", 3000)))
	equal(P.width(dated.responses[#dated.responses].text), 2000, "long responses cut, on a character")

	-- Summaries have Markdown or numbered headings, and may have neither kind.
	local numbered = P.summary_lines("1. Primary Request and Intent:\n   Old\n8. Current Work:\n   Now\n9. \"a quote\": kept text\n")
	equal(numbered[1].heading, "Current Work", "numbered heading")
	equal(numbered[2].text, "   Now", "numbered section's text")
	equal(numbered[3].text:sub(1, 2), "9.", "a numbered line that isn't a heading")
	equal(#numbered, 3, "only sections about where work stands")
	local bare = P.new_state()
	P.record(bare, { type = "user", timestamp = "2026-11-03T14:00:00Z", isCompactSummary = true, message = { content = "Just prose" } })
	has(plain(P.log_lines(bare, 60)), "No current state", "a summary with nothing to show")

	-- Foldable headings hide their sections, click to toggle, and stay in place.
	local tested = P.new_state()
	tested.tests[1] = { command = "npm test", ok = true }
	local open = P.info_lines(tested, 60)
	has(plain(open), "▾ ▷ Tests 1\n\n", "unfolded heading, with a blank row under it")
	has(plain(open), "▾ ◇ Open none\n\n▾ ▷ Tests", "no extra blank row under an empty section")
	has(plain(open), "▾ ✗ Failed commands none", "an empty last section")
	equal(open[#open]:find("Failed", 1, true) ~= nil, true, "nothing after an empty last section")
	has(plain(open), "npm test", "unfolded body")
	has(plain(open), "◆ Session", "session icon")
	has(plain(P.info_lines(P.new_state(), 40, { five_hour = { used_percentage = 5 } }, 1000)), "▤ Usage\n\nSession (5h)", "blank row under a fixed heading")
	local closed = P.info_lines(tested, 60, nil, nil, { Tests = true })
	has(plain(closed), "▸ ▷ Tests 1\n\n▾", "folded heading keeps its count, and one blank row")
	hasnt(plain(closed), "npm test", "folded body")
	has(plain(closed), "▾ ✗ Failed commands", "other sections stay open")
	local tests_line
	for line, action in pairs(closed.actions) do
		if action.name == "Tests" then
			tests_line = line
		end
	end
	has(closed[tests_line], "Tests", "the action is on the heading's line")
	equal(closed.actions[tests_line].kind, "fold", "heading click")
	local layout_fold = { tabs = {}, hits = {}, pinned = 0, actions = closed.actions, scroll = 0 }
	equal(P.hit(layout_fold, 1, tests_line + 2).name, "Tests", "a click lands on the heading")
	equal(#closed.sections, 3, "Info's foldable sections")
	equal(#P.log_lines(tested, 60).sections, 4, "Log's foldable sections")
	has(P.info_lines(tested, 60, nil, nil, nil, "Tests")[tests_line], "\27[7m", "highlighted heading")

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
return "cc-sidecar: all tests passed"
