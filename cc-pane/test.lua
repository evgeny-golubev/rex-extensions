-- Run: rex do ~/.config/rex/extensions/cc-pane/test.lua
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
		terminal("block:9", "Changes: old"),
	}
	processes = {
		["block:1"] = { foreground = { argv0 = "claude", cwd = "/src/app/sub" } },
		["block:2"] = { foreground = { argv0 = "nvim", cwd = "/src/app" } },
	}
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
			return { block_ids = { "block:changes" .. next_id } }
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
	after = function(_, fn)
		table.insert(timers, fn)
	end,
	log = function() end,
	stop = function()
		stopped = true
		error("STOP", 0)
	end,
}

local ok, err = pcall(function()
	-- At start, closes stale changes panes and opens one beside a running Claude.
	reset()
	run()
	equal(closed[1], "block:9", "stale pane closed")
	equal(#splits, 1, "panes opened at start")
	local split = splits[1]
	equal(split.anchor_id, "block:1", "anchor")
	equal(split.direction, "horizontal", "direction")
	equal(split.side, "after", "side")
	equal(split.ratio, 0.8, "ratio")
	equal(split.focus, false, "focus")
	equal(split.layout.block.label, "Changes: app", "label")
	equal(split.layout.block.options.cwd, "/src/app", "cwd is the repository root")
	local command = split.layout.block.options.command
	equal(command[3], "do", "viewer runs with rex do")
	equal(command[4], dir .. "panel.lua", "viewer")
	equal(command[5], "claude=block:1", "viewer's Claude pane")
	equal(command[6], "cwd=/src/app", "viewer's repository")
	fire()
	equal(resized[1].before_block_id, "block:1", "resized left")
	equal(resized[1].after_block_id, "block:changes1", "resized right")
	equal(resized[1].ratio, 0.8, "resized ratio")

	-- The same Claude doesn't get a second pane, and a command it runs in the
	-- foreground doesn't close it.
	foreground("block:1", "claude", "/src/app/sub")
	foreground("block:1", "git", "/src/app", { { argv0 = "claude" }, { argv0 = "-zsh" } })
	equal(#splits, 1, "panes after repeated events")
	equal(#closed, 1, "closed while Claude runs")

	-- Claude exiting closes its pane.
	foreground("block:1", "-zsh", "/src/app", { { argv0 = "login" } })
	equal(closed[2], "block:changes1", "pane closed on exit")

	-- Claude outside a repository gets a pane in its own directory.
	foreground("block:2", "/usr/local/bin/claude", "/tmp")
	equal(#splits, 2, "pane outside a repository")
	equal(splits[2].layout.block.label, "Changes: tmp", "label outside a repository")
	equal(splits[2].layout.block.options.command[6], "cwd=/tmp", "directory outside a repository")
	user_closes("block:2")

	-- A pane the user closes stays closed until Claude starts again.
	foreground("block:1", "claude", "/src/app")
	equal(#splits, 3, "pane for a new Claude")
	user_closes("block:changes3")
	foreground("block:1", "claude", "/src/app")
	equal(#splits, 3, "reopened after the user closed it")
	foreground("block:1", "-zsh", "/src/app")
	equal(#closed, 3, "closed a pane that is already gone")
	foreground("block:1", "claude", "/src/app")
	equal(#splits, 4, "pane for the next Claude")

	-- Closing the Claude pane closes its changes pane.
	user_closes("block:1")
	equal(closed[4], "block:changes4", "pane closed with its Claude pane")

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
	equal(closed[5], "block:changes5", "rechecked pane closed")
	fire()
	fire()
	equal(#timers, 0, "rechecks repeat")

	-- A second copy quits.
	reset()
	clients = { { info = { label = "cc-pane" } } }
	run()
	equal(stopped, true, "second copy stopped")
	equal(#splits, 0, "second copy's panes")
end)
rex = real
if not ok then
	error(err, 0)
end

-- The viewer, on a made-up transcript.
CC_PANE_TEST = true
local P = dofile(dir .. "panel.lua")
CC_PANE_TEST = nil

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

	local context = plain(P.context_lines(state, 60))
	has(context, "Add tabs to the panel", "prompt")
	has(context, "/review high", "slash command")
	has(context, "Also add a hint", "queued prompt")
	equal(#state.prompts, 3, "prompts, without meta, notices, duplicates or subagents")
	has(context, "Which tabs?", "question")
	has(context, "→ Diff and Context", "answer")
	has(context, "keep Diff first", "answer note")
	has(context, "Plan approved: Tabbed panel", "plan")
	has(context, "Rejected Bash: rm -rf build", "rejected action")
	has(context, "keep build", "what the user said")
	has(context, "? Ship it now?", "waiting question")
	has(context, "? Should I also add a third tab?", "question in the last reply")
	has(context, "○ Draw the tabs", "open task")
	hasnt(context, "Write the parser", "completed task")
	has(context, "▸ Update the README", "todo in progress")
	has(context, "Current state", "summary section")
	local many = P.new_state()
	for i = 1, 7 do
		many.prompts[i] = { text = "request " .. i }
	end
	local recent = plain(P.context_lines(many, 60))
	has(recent, "Requests last 5 of 7", "requests count")
	has(recent, "request 7", "newest request")
	has(recent, "request 3", "fifth newest request")
	hasnt(recent, "request 2", "older request")
	has(context, "parser done", "summary text")
	hasnt(context, "old", "summary sections that aren't about where work stands")
	hasnt(context, "If you need", "Claude Code's note after the summary")

	-- A prompt after the reply answers its questions.
	P.feed(state, rex.json.encode({ type = "user", message = { content = "No third tab" } }) .. "\n")
	hasnt(plain(P.context_lines(state, 60)), "third tab?", "answered reply question")

	local activity = plain(P.activity_lines(state, 60, "/src/app", { ["/src/app/panel.lua"] = true }))
	has(activity, "● panel.lua ×2", "edited file in the diff")
	local use_outside = P.activity_lines(state, 60, "/elsewhere", {})
	has(plain(use_outside), "+ 1 outside the repository", "files outside the repository")
	hasnt(activity, "gone.lua", "failed write")
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
	equal(P.clip_left("/a/long/path/file.lua", 10), "…/file.lua", "clip left")
	equal(P.project_dir("/Users/a.b/My App"), "-Users-a-b-My-App", "project folder")
	equal(P.claude_pid({ foreground = { argv0 = "git" }, ancestors = { { argv0 = "/bin/claude", pid = 7 } } }), 7, "pid")

	-- The status, from one porcelain call.
	local st = P.status("## main...origin/main [ahead 1]\0 M a.lua\0R  new.lua\0old.lua\0?? docs/x.md\0", "/r")
	equal(#st.lines, 4, "status lines")
	has(plain(st.lines), "## main...origin/main [ahead 1]", "branch line")
	has(plain(st.lines), "R  old.lua -> new.lua", "rename")
	has(plain(st.lines), "?? docs/x.md", "untracked file")
	equal(st.changed["/r/new.lua"] and st.changed["/r/docs/x.md"] and not st.changed["/r/old.lua"], true, "changed paths")
	equal(st.head, true, "branch with commits")
	equal(P.status("## No commits yet on main\0", "/r").head, false, "branch without commits")

	-- Tabs: Activity first, Diff only in a repository.
	equal(table.concat(P.tabs(true), ","), "Activity,Context,Diff", "tabs in a repository")
	equal(table.concat(P.tabs(false), ","), "Activity,Context", "tabs elsewhere")
	local tabs = P.tabs(true)

	-- The frame fills the pane and no more, and says where it is when the
	-- lines don't fit.
	local frame = P.frame(tabs, "Context", { "a", "b", "c", "d" }, 1, 60, 4)
	local _, count = frame:gsub("\r\n", "")
	equal(count, 3, "frame rows")
	has(frame, "\27[K\r\n\27[K\r\nb", "blank row under the tab bar")
	equal(P.width(P.frame(tabs, "Diff", { string.rep("x", 60) }, 0, 40, 4):match("\r\n\27%[K\r\n(.-)\27%[K")), 39, "last column left free")
	has(frame, "2 Context", "tab bar")
	has(frame, "2–3 of 4", "position")
	hasnt(P.frame(tabs, "Diff", { "a" }, 0, 40, 4), " of ", "position when everything fits")
	hasnt(frame, "\r\na\27", "scrolled past the first line")
end)
if not ok2 then
	error(err2, 0)
end
return "cc-pane: all tests passed"
