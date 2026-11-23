-- Run: rex do ~/.config/rex/extensions/rex-sidecar/test.lua
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
REX_SIDECAR_TEST_BASE = test_base
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

	-- Codex gets a pane the same way, and loses it on exit.
	foreground("block:4", "/opt/homebrew/bin/codex", "/src/app")
	equal(#splits, 6, "pane for Codex")
	equal(splits[6].anchor_id, "block:4", "beside Codex")
	foreground("block:4", "-zsh", "/src/app")
	equal(closed[7], "block:sidecar6", "pane closed when Codex exits")

	-- A second copy quits.
	reset()
	clients = { { info = { label = "rex-sidecar" } } }
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
REX_SIDECAR_TEST_BASE = nil
if not ok then
	error(err, 0)
end

-- The viewer, on a made-up transcript, with settings.json in a throwaway folder.
local panel_base = real.exec({ "mktemp", "-d" }).stdout:gsub("%s+$", "") .. "/"
REX_SIDECAR_TEST, REX_SIDECAR_TEST_BASE = true, panel_base
local P = dofile(dir .. "panel.lua")
REX_SIDECAR_TEST, REX_SIDECAR_TEST_BASE = nil, nil
P.load_plugins(dir .. "tabs/")
local C, A = P.plugins.Changes.tab, P.plugins.Artifacts.tab

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
	-- Completed tool inputs are released once tool_result arrives; only waiting questions stay.
	equal(state.tools.e1, nil, "completed Edit input freed from state.tools")
	equal(state.tools.q2 ~= nil, true, "unanswered AskUserQuestion kept in state.tools")

	-- A prompt after the reply answers its questions.
	P.feed(state, rex.json.encode({ type = "user", message = { content = "No third tab" } }) .. "\n")
	hasnt(plain(P.info_lines(state, 60)), "third tab?", "answered reply question")

	local activity = plain(P.info_lines(state, 60, { show = "tests" }))
	has(activity, "tests 1 ✓0 ✗1", "test totals in the receipt")
	has(activity, "✗ rex do test.lua", "failed test, listed")
	equal(#state.tests, 1, "a command that only names a test file")
	hasnt(activity:match("╭ turns.-╰[^\n]+") or "", "cat test.lua", "a command that only names a test file")
	has(plain(P.info_lines(state, 60, { show = "failed" })), "exit 1: boom: parser", "failure, listed")
	hasnt(plain(P.info_lines(state, 60)), "exit 1: boom", "lists closed by default")
	has(activity, "2m", "active time")
	has(activity, "ctx 41k", "context")
	has(activity, "Panel tabs", "session title")
	has(activity, "⎇ main", "branch on its own line")

	-- Git info parsing: normal repo vs linked worktree, and main_box rendering.
	local normal_git = P.parse_git_info("/src/app\n/src/app/.git\n/src/app/.git\nmain\n")
	equal(normal_git.root .. " " .. normal_git.branch, "/src/app main", "normal repo root and branch")
	equal(normal_git.git_dir, "/src/app/.git", "normal repo git_dir for zero-subprocess HEAD reads")
	equal(normal_git.worktree, nil, "normal repo has no linked worktree")
	local wt_git = P.parse_git_info("/src/worktrees/app/feat-ui\n/src/app/.git/worktrees/feat-ui\n/src/app/.git\nfeat/ui-refresh\n")
	equal(wt_git.worktree, "feat-ui", "linked worktree folder name")
	equal(wt_git.repo, "app", "linked worktree parent repo name")
	equal(wt_git.branch, "feat/ui-refresh", "linked worktree branch")
	local wt_view = plain(P.info_lines(state, 70, { branch = wt_git.branch, worktree = wt_git.worktree, repo = wt_git.repo }))
	has(wt_view, "⎇ feat/ui-refresh", "live git branch overrides transcript branch")
	has(wt_view, "⑂ app/feat-ui", "worktree shown beside branch")
	local same_wt = plain(P.info_lines(state, 70, { branch = "feat-ui", worktree = "feat-ui", repo = "app" }))
	has(same_wt, "⎇ feat-ui", "branch when worktree matches branch name")
	has(same_wt, "⑂ app wt", "compact worktree badge without repeating branch name")
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
	local st = C.status("## main...origin/main [ahead 1]\0 M a.lua\0R  new.lua\0old.lua\0?? docs/x.md\0MM both.lua\0")
	equal(st.branch, "main", "branch name")
	equal(#st.files, 4, "changed files")
	equal(st.files[2].path, "new.lua", "rename's new path")
	equal(st.head, true, "branch with commits")
	local empty = C.status("## No commits yet on main\0")
	equal(empty.head, false, "branch without commits")
	equal(empty.branch, "main", "branch without commits' name")

	-- Uncommitted: a file changed both ways is in both groups, once in the tree.
	local data = C.uncommitted(st.files)
	equal(data.groups[1].title, "Staged", "first group")
	equal(#data.groups[1].rows, 2, "staged rows")
	equal(data.groups[2].title, "Unstaged", "second group")
	equal(#data.groups[2].rows, 3, "unstaged rows")
	equal(#data.merged, 4, "tree rows")
	equal(data.groups[2].rows[2].mark, "A", "untracked counts as added")
	equal(#C.uncommitted({}).groups, 0, "nothing changed")

	-- Each row's diff.
	local args = function(row, ...)
		return table.concat(C.diff_args(row, ...), " ")
	end
	equal(args({ path = "a", diff = "staged" }), "diff --cached -- a", "staged diff")
	equal(args({ path = "a", diff = "unstaged" }), "diff -- a", "unstaged diff")
	equal(args({ path = "a", diff = "head" }, nil, true), "diff HEAD -- a", "merged diff")
	equal(args({ path = "a", diff = "head" }, nil, false), "diff --cached -- a", "merged diff without commits")
	equal(args({ path = "a", diff = "base" }, "abc"), "diff abc -- a", "branch diff")
	equal(args({ path = "a", diff = "untracked" }), "diff --no-index -- /dev/null a", "untracked diff")

	-- Numbers and the Branch scope.
	local a2, r2 = C.numstat("3\t1\ta.lua\0-\t-\tpic.png\0" .. "2\t0\tb c.lua\0")
	equal(a2, 5, "added")
	equal(r2, 1, "removed")
	local moved_a, moved_r = C.numstat("1\t2\t\0old.lua\0new.lua\0")
	equal(moved_a, 1, "added in a rename")
	equal(moved_r, 2, "removed in a rename")
	local renamed = C.branch_rows("R100\0old.lua\0new.lua\0M\0z.lua\0", {})
	equal(#renamed, 2, "a rename is one row")
	equal(renamed[1].path, "new.lua", "a rename's new path")
	equal(renamed[1].mark, "R", "rename mark")
	local branch = C.branch_rows("M\0z.lua\0D\0b.lua\0", { { x = "?", y = "?", path = "c.lua" }, { x = " ", y = "M", path = "z.lua" } })
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
	local v = { title = "feature/x", scope = "Uncommitted", scopes = C.scopes(true, "Branch"), data = data }
	data.added, data.removed = 7, 2
	local built = C.changes_view(v, 40)
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
	has(plain(C.changes_view(v, 40).lines), "› ", "selected row")
	equal(table.concat(C.scopes(false), ","), "Last Turn", "scopes without git")
	equal(table.concat(C.scopes(true, "PR"), ","), "Last Turn,Uncommitted,PR", "a PR instead of Branch")
	equal(table.concat(C.scopes(true), ","), "Last Turn,Uncommitted", "no Branch on the default branch")
	equal(C.pick_scope(C.scopes(true, "PR"), "Branch"), "PR", "Branch moves to PR")
	equal(C.pick_scope(C.scopes(true, "Branch"), "PR"), "Branch", "PR moves to Branch")
	equal(C.pick_scope(C.scopes(true), "Branch"), "Last Turn", "Branch gone on the default branch")
	equal(C.pick_scope(C.scopes(true), "Uncommitted"), "Uncommitted", "a scope that stays")
	local pr = C.pr_info('{"number":12,"baseRefName":"develop","state":"OPEN"}')
	equal(pr and pr.number, 12, "PR number")
	equal(pr and pr.base, "develop", "PR base")
	equal(C.pr_info('{"number":12,"baseRefName":"develop","state":"MERGED"}'), nil, "merged PR")
	equal(C.pr_info('{"number":12,"baseRefName":"--output=x","state":"OPEN"}'), nil, "a base that reads as an option")
	equal(C.pr_info("no pull requests found"), nil, "no PR")
	equal(C.pr_info(nil), nil, "gh failed")

	-- The tree merges the groups and lists folders.
	v.tree, v.selected = true, nil
	local tree = C.changes_view(v, 40)
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
	local deep = C.changes_view({ title = "m", scope = "Branch", scopes = C.scopes(true, "Branch"), tree = true, data = { groups = { { title = "Changed", rows = {
		{ path = "src/cart/a.ts", mark = "M" }, { path = "src/cart/b.ts", mark = "A" }, { path = "src/ui/c.ts", mark = "M" }, { path = "z.ts", mark = "D" },
	} } }, vs = "main" } }, 30)
	local shown_tree = plain(deep.lines)
	has(shown_tree, "vs main", "what the branch compares with")
	local _, cart_count = shown_tree:gsub("▾ cart", "")
	equal(cart_count, 1, "a folder is listed once")
	has(shown_tree, "▾ ui", "sibling folder")
	has(shown_tree, "z.ts", "top-level file")

	-- Folders come before files at each level, each by name.
	local ordered = C.changes_view({ title = "m", scope = "Branch", scopes = C.scopes(true, "Branch"), tree = true, data = { groups = { { title = "Changed", rows = {
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
		return C.changes_view({ title = "m", scope = "Branch", scopes = C.scopes(true, "Branch"), tree = true, folded = folded, selected = selected,
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
	local narrow, narrow_ranges = C.scope_bar(C.scopes(true, "Branch"), "Branch", 26)
	has(plain({ narrow }), "Local", "short name")
	hasnt(plain({ narrow }), "Uncommitted", "long name")
	equal(narrow_ranges[3].action.scope, "Branch", "last scope")
	local _, wide_ranges = C.scope_bar(C.scopes(true, "Branch"), "Branch", 60)
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
	usage_state.model, usage_state.context, usage_state.effort, usage_state.mode, usage_state.requests, usage_state.compactions = "claude-opus-5-5", 250000, "high", "auto", 12, 2
	local usage = plain(P.info_lines(usage_state, 60, { now = 1000, status = {
		rate_limits = limits, cost = { total_cost_usd = 3.456 }, context_window = { context_window_size = 1000000 } } }))
	has(usage, "Opus 5.5 · main", "the model's name")
	has(usage, "○ idle", "idle")
	has(usage, "▮▮▮▯▯ high", "effort cells")
	has(usage, "auto", "permission mode")
	has(usage, "12 req", "requests")
	has(usage, "ctx ▰▰▱▱▱▱▱▱ 25%", "context gauge")
	has(usage, "250k/1.0M", "context against the window")
	has(usage, "⟲ 2", "compaction count separated from the icon")
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
	has(plain(P.info_lines(levels, 60)), "▮▮▯▯▯ medium", "the effort in the main box")
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
	equal(P.width(open[3]), 60, "a box fills the width, under the clock and a blank line")
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
	local running_lines = P.info_lines(tested, 60, { now = 130, clock = 10.0 })
	local running = plain(running_lines)
	has(running, " turn 30s", "a running turn's clock")
	has(running, "● running", "running, in the main box")
	equal(running_lines.ticking, true, "the clock ticks")
	equal(running_lines.fast, true, "active turn enables 60 Hz header patching")
	equal(type(running_lines.turn_header), "table", "turn_header descriptor recorded for single-row patching")
	local box_a = P.turn_box_lines(running_lines.turn_header, 60, 112.4, 10.0, true)
	local box_b = P.turn_box_lines(running_lines.turn_header, 60, 112.5, 10.016, true)
	has(plain({ box_a[1] }), "turn 12.4s", "precise sub-second elapsed timer under 60s")
	equal(#box_a >= 3, true, "turn_box_lines renders top, body, and bottom border")
	equal(box_a[1] ~= box_b[1] and box_a[#box_a] ~= box_b[#box_b], true, "60 Hz gradient sweeps top and bottom borders in unison")

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
	equal(next(agent.calls), nil, "subagent completed tool calls freed from memory")
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
	local hm0 = os.date("%H:%M", P.epoch("2026-11-17T10:00:01Z"))
	has(log_view, hm0 .. " › Fix the cart", "a prompt with its grouped HH:MM timestamp")
	has(log_view, "      ✦ started · Map the cart", "an agent's start, blanking repeated HH:MM")
	has(log_view, "      ✦ done · Map the cart", "and end")
	has(log_view, "      ✗ Write /w/a.lua", "a denial")
	local short = plain(P.info_lines(logged, 60, { rows = 1 }))
	hasnt(short, "Fix the cart", "only the latest when there's no room")
	has(short, "✗ Write", "at least 3 events")

	-- Compact log formatting: path shortening, ×N grouping, prompt preservation, categories.
	local compact = P.new_state()
	local t0 = P.epoch("2026-11-17T10:00:00Z")
	local t1 = P.epoch("2026-11-17T10:01:00Z")
	compact.log = {
		{ at = t0, who = "main", text = "› retry" },
		{ at = t0 + 1, who = "main", text = "› retry" },
		{ at = t0 + 2, who = "main", text = "edit → /very/deep/path/src/panel.lua" },
		{ at = t0 + 3, who = "main", text = "edit → /very/deep/path/src/panel.lua" },
		{ at = t0 + 4, who = "main", text = "edit → /very/deep/path/src/panel.lua" },
		{ at = t0 + 5, who = "main", text = "write → /tmp/out/new.lua" },
		{ at = t0 + 6, who = "main", text = "delete → /tmp/out/old.lua" },
		{ at = t0 + 7, who = "main", text = "workflow → build" },
		{ at = t1, who = "advisor", text = "consulted" },
		{ at = t1 + 1, who = "main", text = "Compacted context" },
	}
	local compact_raw = P.info_lines(compact, 60, { rows = 40 })
	local compact_plain = plain(compact_raw)
	local hm1 = os.date("%H:%M", t1)
	local _, retry_count = compact_plain:gsub("› retry", "")
	equal(retry_count, 2, "consecutive identical prompts are not collapsed")
	has(compact_plain, "✎ src/panel.lua ×3", "consecutive identical edits collapse with compact parent/file")
	hasnt(compact_plain, "/very/deep/path", "long directory prefixes dropped")
	has(compact_plain, "+ out/new.lua", "write icon and compact path")
	has(compact_plain, "- out/old.lua", "delete icon and compact path")
	has(compact_plain, "▷ build", "workflow icon")
	has(compact_plain, hm1 .. " ♦ consulted", "new minute prints its HH:MM and advisor icon")
	has(compact_plain, "      ⟲ Compacted context", "lifecycle icon in the same minute")
	local compact_ansi = table.concat(compact_raw, "\n")
	has(compact_ansi, "\27[38;2;212;178;106m✎", "edit category in muted sand")
	has(compact_ansi, "\27[38;2;134;189;134m+", "write category in soft sage-mint")
	has(compact_ansi, "\27[38;2;107;168;160m▷", "workflow category in soft teal")
	has(compact_ansi, "\27[38;2;169;142;212m♦", "advisor category in muted purple")

	-- Rich log categories across all agents + clickable exploration burst expansion.
	equal(P.short_url("https://developers.openai.com/codex/cli/"), "developers.openai.com/codex/cli", "short_url")
	equal(P.short_mcp("mcp__claude_ai_Atlassian_MCP__createJiraIssue"), "atlassian·createJiraIssue", "short_mcp strips noisy prefixes")
	equal(P.is_read_command("git -C /src status"), true, "git status is read-only exploration")
	equal(P.is_read_command("which codex"), false, "which is a regular command")
	equal(P.is_read_command("cd '/Users/me/My App' 2>/dev/null && ls; grep -rn 'a|b' . 2>/dev/null | head -5"), true, "compound read-only command is exploration")
	equal(P.is_read_command("uptime; echo; sysctl -n hw.ncpu; df -h / 2>/dev/null"), true, "compound system inspection is exploration")
	equal(P.is_read_command("ls /a | sed -E 's/.*\\.//' | sort | uniq -c"), true, "non-in-place sed pipe is read-only")
	equal(P.is_read_command("sed -i '' 's/a/b/' file.txt"), false, "in-place sed is mutating")
	equal(P.is_read_command("test -e /a/.mcp && echo yes || echo no"), true, "test existence check is read-only")
	equal(P.is_read_command("for f in ~/.mcp.json ~/a/.mcp.json; do [ -f \"$f\" ] && grep -l sentry \"$f\"; done"), true, "read-only for-loop is exploration")
	equal(P.is_read_command("git -C '/a/b' rev-parse --show-toplevel 2>&1"), true, "quoted git -C read command is exploration")
	equal(P.is_read_command("pgrep -lf gopls; kill 123"), false, "chained command with mutating step is not read-only")
	equal(P.is_read_command("cat a.txt > b.txt"), false, "output redirection is not read-only")
	equal(P.is_read_command("cat >> out.md <<'EOF'\nhi\nEOF"), false, "multiline/heredoc command is not read-only")
	equal(P.command("cd '/a/My App' && git diff"), "git diff", "quoted cd prefix stripped")
	equal(P.command("cd '/a'/sub && git show HEAD:x"), "git show HEAD:x", "mixed-quote cd prefix stripped")
	equal(P.display_command("d=~/out/2026; python3 run.py"), "python3 run.py", "leading var setup stripped for fallback display")
	equal(P.display_command("rm -rf '/src/app/.tmp'", "/src/app"), "rm -rf '.tmp'", "session root shortened inside raw commands")
	-- Claude Bash description + click-to-peek raw command + plumbing filtering.
	local sh = P.new_state("claude")
	P.record(sh, use("b_ren", "Bash", { command = 'rex session rename "$REX_SESSION" foo', description = "Name session" }))
	P.record(sh, result("b_ren", "ok"))
	P.record(sh, use("b_rd", "Read", { file_path = "/Users/u/.claude/projects/p/s/tool-results/abc123.txt" }))
	P.record(sh, result("b_rd", "ok"))
	P.record(sh, use("b_desc", "Bash", { command = "d=~/out; python3 summarize.py", description = "Summarise hot threads" }))
	P.record(sh, result("b_desc", "ok"))
	local sh_view = P.info_lines(sh, 64, { rows = 40 })
	local sh_plain = plain(sh_view)
	hasnt(sh_plain, "Name session", "rex session rename omitted from log")
	hasnt(sh_plain, "tool-results", "internal tool-results spill read omitted")
	has(sh_plain, "$ Summarise hot threads", "Bash description shown instead of raw command")
	hasnt(sh_plain, "python3 summarize.py", "raw command hidden until clicked")
	local sh_id
	for _, a in pairs(sh_view.actions) do
		if a.kind == "log_group" then sh_id = a.id end
	end
	equal(sh_id ~= nil, true, "described shell command has clickable peek action")
	local sh_open = plain(P.info_lines(sh, 64, { rows = 40, open_logs = { [sh_id] = true } }))
	has(sh_open, "$ d=~/out; python3 summarize.py", "clicking described shell command reveals raw command")
	local rich = P.new_state("codex")
	rich.log = {
		{ at = t0, who = "main", text = "› check codex" },
		{ at = t0 + 1, who = "main", text = "read skills/SKILL.md", kind = "explore" },
		{ at = t0 + 2, who = "main", text = "read src/a.lua", kind = "explore" },
		{ at = t0 + 3, who = "main", text = "read src/b.lua", kind = "explore" },
		{ at = t0 + 4, who = "main", text = "which codex", kind = "cmd" },
		{ at = t0 + 5, who = "main", text = "developers.openai.com/codex/cli", kind = "web" },
		{ at = t0 + 6, who = "main", text = "atlassian·createJiraIssue", kind = "mcp" },
		{ at = t0 + 7, who = "main", text = "pytest -q", kind = "test_ok" },
	}
	local collapsed_view = P.info_lines(rich, 60, { rows = 40 })
	local collapsed_plain = plain(collapsed_view)
	has(collapsed_plain, "▸ read 3 files", "consecutive reads collapse into clickable summary")
	hasnt(collapsed_plain, "SKILL.md", "collapsed burst hides individual reads")
	has(collapsed_plain, "$ which codex", "command icon")
	has(collapsed_plain, "↗ developers.openai.com/codex/cli", "web open icon")
	has(collapsed_plain, "⬡ atlassian·createJiraIssue", "mcp tool icon")
	has(collapsed_plain, "✓ pytest -q", "passing test icon")
	local group_id
	for _, a in pairs(collapsed_view.actions) do
		if a.kind == "log_group" then
			group_id = a.id
		end
	end
	equal(group_id, 2, "collapsed exploration burst has clickable log_group action")
	local expanded_plain = plain(P.info_lines(rich, 60, { rows = 40, open_logs = { [group_id] = true } }))
	has(expanded_plain, "▾ read 3 files", "expanded exploration burst header")
	has(expanded_plain, "◦ read skills/SKILL.md", "expanded burst shows individual read items")
	has(expanded_plain, "◦ read src/b.lua", "expanded burst shows all items")
	-- Monotonic log IDs keep expanded burst IDs stable even when the 300-entry ring buffer trims.
	local ring = P.new_state()
	for k = 1, 298 do
		P.log(ring, "main", "cmd " .. k, "cmd")
	end
	P.log(ring, "main", "read a.lua", "explore")
	P.log(ring, "main", "read b.lua", "explore")
	local before_id
	for _, a in pairs(P.info_lines(ring, 60, { rows = 40 }).actions) do
		if a.kind == "log_group" then before_id = a.id end
	end
	P.log(ring, "main", "cmd 301", "cmd")
	local after_id
	for _, a in pairs(P.info_lines(ring, 60, { rows = 40 }).actions) do
		if a.kind == "log_group" then after_id = a.id end
	end
	equal(after_id, before_id, "log_group id stays stable after ring-buffer trim")
	-- Codex parsed_cmd read + web.search Extension + McpToolCall logging.
	local cx_log = P.new_state("codex")
	P.record(cx_log, { type = "event_msg", payload = { type = "item_completed", item = {
		type = "CommandExecution", command = { "/bin/zsh", "-lc", "cat /x/SKILL.md" },
		parsed_cmd = { { type = "read", name = "SKILL.md", path = "/x/SKILL.md" } },
		status = "completed", exit_code = 0,
	} } })
	P.record(cx_log, { type = "event_msg", payload = { type = "item_completed", item = {
		type = "CommandExecution", command = { "/bin/zsh", "-lc", "which codex" },
		status = "completed", exit_code = 0,
	} } })
	P.record(cx_log, { type = "event_msg", payload = { type = "item_completed", item = {
		type = "Extension", kind = "web.search", action = { type = "openPage", url = "https://developers.openai.com/codex/cli" },
	} } })
	local cx_log_plain = plain(P.info_lines(cx_log, 60, { rows = 40 }))
	has(cx_log_plain, "◦ read x/SKILL.md", "single codex read shows file directly without needing expand")
	has(cx_log_plain, "$ which codex", "codex shell command logged")
	has(cx_log_plain, "↗ developers.openai.com/codex/cli", "codex web.search openPage logged")
	-- Claude SendMessage: hide opaque hex agent IDs, prefer summary/message; keep readable names.
	local sm = P.new_state("claude")
	P.record(sm, use("sm1", "SendMessage", { to = "a788bf8a9b8107fe1", summary = "Follow-up config questions", message = "Long body" }))
	P.record(sm, result("sm1", "ok"))
	P.record(sm, use("sm2", "SendMessage", { to = "disco-search", message = "Keep dob only" }))
	P.record(sm, result("sm2", "ok"))
	local sm_plain = plain(P.info_lines(sm, 70, { rows = 40 }))
	has(sm_plain, "✦ msg · Follow-up config questions", "SendMessage uses summary instead of hex ID")
	hasnt(sm_plain, "a788bf8a9b8107fe1", "opaque hex agent ID hidden from log")
	has(sm_plain, "✦ msg · disco-search: Keep dob only", "named agent keeps name + message preview")

	-- The advisor's consults.
	local advised = P.new_state()
	advised.prompts[1] = { text = "start", seq = 1, at = "1970-01-01T00:00:00Z" }
	advised.consults = { { id = "s1", at = 100, done = 127 } }
	local advice = plain(P.info_lines(advised, 60, { now = 134 }))
	has(advice, "ADVISOR · on call", "the advisor box")
	has(advice, "consults 1", "consults")
	has(advice, "─╴♦╶─", "advisor diamond centered with tight half-cell breaks")
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
	local view = A.artifacts_view(groups, 40, {}, nil, nil)
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
	hasnt(plain(A.artifacts_view(groups, 40, { Documents = true }).lines), "notes.md", "folded")
	has(plain(A.artifacts_view({}, 40, {}).lines), "Nothing in Claude's replies yet.", "nothing found")
	has(plain(A.artifacts_view({}, 40, {}, nil, "boom").pinned), "boom", "a notice under the link")
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
	local pr_view = plain(A.artifacts_view(pr_groups, 60, {}, nil, nil, { ["https://github.com/acme/shop/pull/42"] = "Add rate-limit guard" }).lines)
	has(pr_view, "#42 Add rate-limit guard", "a PR's number before its title")
	has(pr_view, "╭ ⇄ PRs", "the PRs box")
	has(pr_view, "Add rate-limit guard", "a PR by its title")
	has(pr_view, "  # 123", "a comment under its PR")
	has(pr_view, "  files", "the files under their PR")
	has(pr_view, "│ acme/api#7  ", "a PR with no title yet, and one link")
	has(pr_view, "acme/web#1  # 8", "a PR's only link, on its row")
	hasnt(pr_view, "guard  acme/shop#42", "no repository and number beside a title")
	local pr_actions = {}
	for _, a in pairs(A.artifacts_view(pr_groups, 60, {}).actions) do
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
	local capped = A.artifacts_view(V.group({ many }), 60, {})
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
	has(plain(A.artifacts_view(jira_groups, 60, {}).lines), "SHOP-12 Cart rounding", "the key, then the title")
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

do
	-- Codex: a rollout read through its parser into the same state.
	local at = "2026-11-18T04:19:39.000Z"
	local function ev(t, payload)
		payload.type = t
		return { timestamp = at, type = "event_msg", payload = payload }
	end
	local function item(it)
		return ev("item_completed", { item = it })
	end
	local function text(t)
		return { { type = "Text", text = t } }
	end
	local rollout = {
		{ timestamp = at, type = "session_meta", payload = { cwd = "/src/app", git = { branch = "feature" } } },
		{ timestamp = at, type = "turn_context", payload = { cwd = "/src/app", model = "gpt-test", effort = "high", approval_policy = "on-request", sandbox_policy = { type = "workspace-write" } } },
		ev("task_started", {}),
		item({ type = "UserMessage", content = { { type = "text", text = "Fix the parser" } } }),
		item({ type = "AgentMessage", content = text("Looking."), phase = "commentary" }),
		item({ type = "CommandExecution", command = { "/bin/zsh", "-lc", "cd /src/app && pytest -q tests" }, status = "failed", exit_code = 1, aggregated_output = "1 failed\nmore" }),
		item({ type = "CommandExecution", command = { "/bin/zsh", "-lc", "ls" }, status = "completed", exit_code = 0, aggregated_output = "" }),
		item({ type = "FileChange", status = "completed", changes = {
			["/src/app/a.lua"] = { type = "update", unified_diff = "@@ -1,2 +1,2 @@\n x\n-old\n+new\n\n@@ -10 +10,2 @@\n y\n+z\n" },
			["/src/app/b.lua"] = { type = "add", content = "one\ntwo\n" },
			["/src/app/c.lua"] = { type = "delete", content = "gone\n" },
		} }),
		item({ type = "SubAgentActivity", kind = "started", agent_path = "/root/review_parser", agent_thread_id = "t2" }),
		item({ type = "McpToolCall", server = "linear", tool = "get_issue", status = "failed" }),
		item({ type = "ContextCompaction" }),
		ev("token_count", {
			info = { last_token_usage = { input_tokens = 50000 }, model_context_window = 200000 },
			rate_limits = { primary = { used_percent = 40, window_minutes = 300, resets_at = 2000 }, secondary = { used_percent = 10, window_minutes = 10080 } },
		}),
		item({ type = "AgentMessage", content = text("Fixed it. See https://example.com/pr/1"), phase = "final_answer" }),
		ev("task_complete", { duration_ms = 65000 }),
	}
	local lines = {}
	for i, r in ipairs(rollout) do
		lines[i] = rex.json.encode(r)
	end
	-- Records Codex writes with these keys first: a usage record counts as a
	-- request, and raw model items and reasoning aren't read.
	lines[#lines + 1] = '{"timestamp":"' .. at .. '","ordinal":40,"type":"token_usage_record","payload":{}}'
	lines[#lines + 1] = '{"timestamp":"' .. at .. '","ordinal":41,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"SHOULD NOT APPEAR"}]}}'
	lines[#lines + 1] = '{"timestamp":"' .. at .. '","ordinal":42,"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning"}}}'
	local cx = P.new_state("codex")
	local all = table.concat(lines, "\n") .. "\n"
	P.feed(cx, all:sub(1, 300))
	P.feed(cx, all:sub(301))

	equal(cx.model, "gpt-test", "codex model")
	equal(cx.effort, "high", "codex effort")
	equal(cx.mode, "on-request · workspace-write", "codex approval and sandbox")
	equal(cx.branch, "feature", "codex branch")
	equal(cx.root, "/src/app", "codex directory")
	equal(#cx.prompts, 1, "codex prompts")
	equal(cx.prompts[1].text, "Fix the parser", "codex prompt")
	equal(#cx.responses, 1, "one response per turn")
	equal(cx.responses[1].text, "Fixed it. See https://example.com/pr/1", "the last message is the response")
	equal(cx.requests, 1, "usage records count requests")
	equal(cx.compactions, 1, "codex compactions")
	local written
	for _, e in ipairs(cx.log) do
		written = written or (e.text == "Write → b.lua")
	end
	equal(written, true, "a new codex file logs as a write")
	equal(cx.claude_ms, 65000, "codex working time")
	equal(P.running(cx), false, "idle after the turn completes")
	equal(cx.context, 50000, "codex context")
	equal(cx.status.window, 200000, "codex context window")
	equal(cx.status.limits[1].label, "5h", "primary limit")
	equal(cx.status.limits[1].used, 40, "primary limit used")
	equal(cx.status.limits[2].label, "7d", "secondary limit")
	equal(#cx.tests, 1, "codex test command")
	equal(cx.tests[1].ok, false, "failed test run")
	equal(cx.failures[1].error, "exit 1: 1 failed", "failure's first line")
	equal(cx.turn.edits, 3, "codex edits")
	equal(cx.turn.errors, 2, "codex errors: a command and an MCP call")
	equal(cx.turn.agents, 1, "codex subagents started")

	local turn = P.turn_data(cx, cx.root)
	local marks = {}
	for _, r in ipairs(turn.groups[1].rows) do
		marks[r.path] = r.mark
	end
	equal(marks["a.lua"], "M", "updated file")
	equal(marks["b.lua"], "A", "added file")
	equal(marks["c.lua"], "D", "deleted file")
	equal(turn.added, 4, "codex lines added")
	equal(turn.removed, 2, "codex lines removed")
	local patch = P.turn_patch(cx, "/src/app/a.lua", "a.lua")
	has(patch, "@@ -1,2 +1,2 @@\n x\n-old\n+new\n@@ -10,1 +10,2 @@\n y\n+z", "hunks without the blank line between them")

	local info = plain(P.info_lines(cx, 70, { now = 1000, agent_name = "Codex", session_name = "Parser fix" }))
	has(info, "gpt-test · main", "codex main box")
	has(info, "Parser fix", "session name without an AI title")
	has(info, "ctx", "codex context shown")
	has(info, "5h", "codex limits shown")
	has(info, "1m", "codex working time")
	hasnt(info, "SHOULD NOT APPEAR", "raw model items skipped")
	has(plain(P.info_lines(P.new_state("codex"), 60, { agent_name = "Codex" })), "Nothing from Codex yet.", "empty codex session")
	-- The session's limits win over the transcript's; its window comes from the transcript.
	local fresh = plain(P.info_lines(cx, 70, { now = 1000, agent_name = "Codex", status = { limits = { { label = "7d", used = 99, resets_at = 5000 } } } }))
	has(fresh, "99%", "account limits from the session")
	has(fresh, "25%", "context window from the transcript")

	local started = P.new_state("codex")
	P.feed(started, rex.json.encode(ev("task_started", {})) .. "\n")
	equal(P.running(started), true, "a turn without a prompt still runs")
	equal(cx.subagent_status.t2, "started", "a subagent's latest activity")
	P.record(started, item({ type = "SubAgentActivity", kind = "completed", agent_thread_id = "t2" }))
	equal(started.subagent_status.t2, "completed", "a finished subagent")

	local declined = P.new_state("codex")
	P.record(declined, item({ type = "CommandExecution", command = { "pytest" }, status = "declined" }))
	equal(#declined.tests, 0, "a command that didn't run isn't a test run")
	equal(declined.turn.errors, 0, "nor an error")
	P.record(declined, item({ type = "CommandExecution", command = { "false" }, status = "failed" }))
	equal(declined.failures[1].error, "status failed", "a failure without an exit code")

	local cp = P.parsers.codex
	equal(cp.command_text({ "/bin/zsh", "-lc", "echo hi" }), "echo hi", "a shell's script")
	equal(cp.command_text({ "git", "status" }), "git status", "plain arguments")
	local turns = cp.turns(lines, 5)
	equal(#turns, 1, "codex turns")
	equal(turns[1], "Fixed it. See https://example.com/pr/1", "codex turn's final message")
	has(plain(A.artifacts_view({}, 60, {}, nil, nil, {}, "Codex").pinned), "all of Codex's replies", "artifacts name the agent")

	local a = P.new_agent("t2", "codex")
	for _, r in ipairs({
		item({ type = "CommandExecution", command = { "/bin/zsh", "-lc", "rg parser" }, status = "completed", exit_code = 0 }),
		item({ type = "FileChange", status = "completed", changes = { ["/src/app/a.lua"] = { type = "update", unified_diff = "" } } }),
		ev("token_count", { info = { last_token_usage = { input_tokens = 1234 } } }),
		item({ type = "AgentMessage", content = text("Looks right.") }),
	}) do
		P.agent_record(a, r, cx.gate)
	end
	equal(a.steps, 2, "codex subagent steps")
	equal(a.context, 1234, "codex subagent context")
	equal(a.answer, "Looks right.", "codex subagent answer")
	has(plain(a.tools), "Shell", "codex subagent's tool calls")
	equal(cx.gate.total, 0, "codex logs no permission checks")
end
-- The date and time at the top of Info.
do
	local at = os.time({ year = 2026, month = 11, day = 22, hour = 18, min = 4 })
	local time, date = P.date_time(at)
	equal(time .. " " .. date, "18:04 Sun · 22 Nov 2026", "the time and the date")
	local top = plain({ P.info_lines(P.new_state(), 60, { now = at })[1] })
	equal(top, "◷ 18:04  Sun · 22 Nov 2026", "on the first line")
end
-- agy: an Antigravity CLI transcript read through its parser.
do
	local function step(t, fields)
		fields.type, fields.created_at, fields.status = t, fields.created_at or "2026-11-22T16:40:15Z", fields.status or "DONE"
		return fields
	end
	local lines = {
		step("USER_INPUT", { source = "USER_EXPLICIT", content = "<USER_REQUEST>\nFix the parser\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nnow\n</ADDITIONAL_METADATA>" }),
		step("PLANNER_RESPONSE", { source = "MODEL", model = "gemini-test", input_tokens = 900, cache_read_tokens = 100, tool_calls = {
			{ name = "run_command", args = { CommandLine = "pytest -q" } },
			{ name = "run_command", args = { CommandLine = "make lint" } },
			{ name = "write_to_file", args = { TargetFile = "/src/app/new.lua", CodeContent = "one\ntwo\n" } },
			{ name = "replace_file_content", args = { TargetFile = "/src/app/a.lua", ReplacementChunks = { { TargetContent = "old", ReplacementContent = "new" } } } },
		} }),
		step("GENERIC", { source = "MODEL", content = "Created At: x\nThe command exited with code 0.\nOutput: 3 passed" }),
		step("GENERIC", { source = "MODEL", content = "Created At: x\nThe command exited with code 2.\nOutput: lint failed" }),
		step("GENERIC", { source = "MODEL", content = "Created file" }),
		step("GENERIC", { source = "MODEL", content = "Edited file" }),
		step("PLANNER_RESPONSE", { source = "MODEL", model = "gemini-test", input_tokens = 1200, created_at = "2026-11-22T16:41:15Z",
			tool_calls = { { name = "ask_question", args = { questions = { { question = "Keep the old API?", options = { "yes", "no" } } } } } } }),
	}
	local ax = P.new_state("agy")
	ax.root = "/src/app"
	for _, r in ipairs(lines) do
		P.record(ax, r)
	end
	equal(ax.prompts[1].text, "Fix the parser", "the prompt without agy's markup")
	equal(ax.model, "gemini-test", "agy model")
	equal(ax.context, 1200, "agy context")
	equal(ax.requests, 2, "agy requests")
	equal(#ax.tests .. " " .. tostring(ax.tests[1].ok), "1 true", "a passing test run")
	equal(ax.failures[1].command, "make lint", "a failed command")
	equal(ax.turn.files["/src/app/new.lua"].created, true, "a written file")
	equal(ax.turn.files["/src/app/new.lua"].added, 2, "its lines")
	equal(ax.turn.files["/src/app/a.lua"].added .. " " .. ax.turn.files["/src/app/a.lua"].removed, "1 1", "a replacement")
	equal(ax.turn.edits, 2, "two edits")
	has(plain(P.info_lines(ax, 60, { now = os.time() })), "Keep the old API?", "the question waits in Open")
	equal(ax.turn.ms, 60000, "asking ends the turn")
	P.record(ax, step("USER_INPUT", { content = "<USER_REQUEST>yes</USER_REQUEST>" }))
	equal(next(ax.waiting), nil, "an answer ends the question")
	P.record(ax, step("PLANNER_RESPONSE", { model = "gemini-test", content = "Done. See https://example.com/pr/2" }))
	equal(ax.last_text.text, "Done. See https://example.com/pr/2", "the reply")
	local raw = {}
	for _, r in ipairs(lines) do
		raw[#raw + 1] = rex.json.encode(r)
	end
	raw[#raw + 1] = rex.json.encode(step("USER_INPUT", { content = "<USER_REQUEST>yes</USER_REQUEST>" }))
	raw[#raw + 1] = rex.json.encode(step("PLANNER_RESPONSE", { content = "Done." }))
	local turns = P.parsers.agy.turns(raw, 5)
	equal(#turns .. " " .. turns[1], "1 Done.", "agy turns")
	-- CLI edit_file / write_file hunks, model effort, CHECKPOINT, subagents, workflows, and run_command without exit code.
	local ax2 = P.new_state("agy")
	ax2.root = "/src/app"
	P.record(ax2, step("USER_INPUT", { content = "<USER_REQUEST>Update files</USER_REQUEST>" }))
	P.record(ax2, step("CHECKPOINT", { content = "compacted" }))
	P.record(ax2, step("PLANNER_RESPONSE", { model = "gemini-4-neon-high", input_tokens = 200000, tool_calls = {
		{ name = "write_file", args = { Path = "/src/app/new.ts", Content = "a\nb\n" } },
		{ name = "edit_file", args = { Path = "/src/app/old.ts", Target = "old1\nold2", Replacement = "new1" } },
		{ name = "run_command", args = { CommandLine = "ls" } },
		{ name = "run_workflow", args = { Description = "Run vitest", Script = "bunx vitest run" } },
		{ name = "run_workflow", args = { Description = "Background build", Script = "vite build" } },
		{ name = "invoke_subagent", args = { Role = "Reviewer", TypeName = "self" } },
	} }))
	P.record(ax2, step("GENERIC", { status = "DONE", content = "Created file." }))
	P.record(ax2, step("GENERIC", { status = "DONE", content = "Edited file." }))
	P.record(ax2, step("GENERIC", { status = "ERROR", content = "no such directory" }))
	P.record(ax2, step("GENERIC", { status = "DONE", content = "3 passed" }))
	P.record(ax2, step("GENERIC", { status = "RUNNING", content = "Tool is running as a background task" }))
	P.record(ax2, step("GENERIC", { status = "DONE", content = '{"conversationId": "sub-1"}' }))
	equal(ax2.compactions, 1, "agy CHECKPOINT increments compactions")
	equal(ax2.effort, "high", "agy effort extracted from model ID")
	equal(P.model_name("gemini-4-neon-high"), "Gemini 4 Neon", "gemini model name prettified")
	local td = P.turn_data(ax2, ax2.root)
	equal(td.added .. " " .. td.removed, "3 2", "agy edit_file and write_file hunks counted in Last Turn")
	equal(ax2.turn.agents, 1, "invoke_subagent increments turn.agents")
	equal(ax2.agy_roles["sub-1"], "Reviewer", "invoke_subagent role recorded by conversationId")
	equal(ax2.turn.errors, 1, "run_command ERROR without exit code counted; RUNNING workflow is not an error")
	equal(#ax2.tests .. " " .. tostring(ax2.tests[1].ok), "1 true", "run_workflow vitest recorded as passing test")
	local sub = P.new_agent("sub-1", "agy")
	P.agent_record(sub, step("PLANNER_RESPONSE", { input_tokens = 500, content = "Looks good", tool_calls = { { name = "read_file", args = { Path = "/src/app/a.ts" } } } }))
	equal(sub.steps .. " " .. sub.context .. " " .. sub.answer, "1 500 Looks good", "agy subagent transcript parsed")
	-- Native themes come from agents/<id>.lua through P.compile_theme.
	for _, adapter in ipairs(P.agents.list) do
		equal(P.themes[adapter.id] ~= nil, true, adapter.id .. " theme compiled from adapter")
	end
	local custom = P.compile_theme({ accent = "#112233", gradient = { "#010203", "#040506" } })
	equal(custom.accent, "\27[38;2;17;34;51m", "compile_theme converts hex accent")
	equal(custom.agent, "\27[38;2;17;34;51m", "compile_theme falls back agent to accent")
	equal(#custom.gradient, 2, "compile_theme converts hex gradient stops")
	local cl_theme = P.new_state("claude")
	cl_theme.model = "claude-opus-5-5"
	local cl_info = table.concat(P.info_lines(cl_theme, 60, { now = os.time() }), "\n")
	has(cl_info, "38;2;201;100;66", "claude uses Anthropic Deep Clay truecolor gradient")
	has(cl_info, "38;2;106;155;204", "claude clock uses Anthropic Slate Blue")
	local agy_info = table.concat(P.info_lines(ax2, 60, { now = os.time(), model_label = "Gemini 4 Neon (High)", mode = "auto", status = { window = 1048576, limits = {} } }), "\n")
	has(agy_info, "38;2;66;133;244", "agy uses Google Blue truecolor gradient")
	has(agy_info, "38;2;52;168;83", "agy gradient reaches Google Green")
	has(plain({ agy_info }), "Gemini 4 Neon · main", "redundant effort suffix stripped from title")
	has(plain({ agy_info }), "auto", "statusline mode shown")
	local cx_theme = P.new_state("codex")
	cx_theme.model = "gpt-5-codex"
	local cx_info = table.concat(P.info_lines(cx_theme, 60, { now = os.time() }), "\n")
	has(cx_info, "38;2;59;130;246", "codex uses Cobalt Blue truecolor gradient")
end
-- Pi: a Pi session transcript read through its parser.
do
	local function msg(m, at)
		return { type = "message", timestamp = at or "2026-11-22T16:40:15Z", message = m }
	end
	local diff = "    ...\n  9 keep\n-10 old line\n+10 new line\n 11 after\n    ...\n 40 x\n+41 added\n    ..."
	local lines = {
		{ type = "session", cwd = "/src/pi", timestamp = "2026-11-22T16:40:00Z" },
		{ type = "thinking_level_change", thinkingLevel = "high" },
		msg({ role = "user", content = { { type = "text", text = "Tidy the code" } } }),
		msg({ role = "assistant", model = "claude-x", usage = { input = 10, cacheRead = 1000, cacheWrite = 90 }, stopReason = "toolUse", content = {
			{ type = "toolCall", id = "c1", name = "bash", arguments = { command = "npm test" } },
			{ type = "toolCall", id = "c2", name = "edit", arguments = { path = "a.ts", oldText = "old line", newText = "new line" } },
			{ type = "toolCall", id = "c3", name = "write", arguments = { path = "/src/pi/b.md", content = "one\ntwo\n" } },
			{ type = "toolCall", id = "c4", name = "bash", arguments = { command = "make lint" } },
		} }),
		msg({ role = "toolResult", toolCallId = "c1", toolName = "bash", isError = false, content = { { type = "text", text = "3 passed" } } }),
		msg({ role = "toolResult", toolCallId = "c2", toolName = "edit", isError = false, details = { diff = diff } }),
		msg({ role = "toolResult", toolCallId = "c3", toolName = "write", isError = false }),
		msg({ role = "toolResult", toolCallId = "c4", toolName = "bash", isError = true, content = { { type = "text", text = "lint failed" } } }),
		msg({ role = "assistant", model = "claude-x", stopReason = "toolUse", content = {
			{ type = "toolCall", id = "c5", name = "ask_user", arguments = { question = "Keep the old API?" } } } }, "2026-11-22T16:41:15Z"),
	}
	local px = P.new_state("pi")
	for _, r in ipairs(lines) do
		P.record(px, r)
	end
	equal(px.prompts[1].text, "Tidy the code", "pi prompt")
	equal(px.model .. " " .. px.effort .. " " .. px.context, "claude-x high 1100", "pi model, thinking level and context")
	equal(px.requests, 2, "pi requests")
	equal(px.failures[1].command, "make lint", "a failed pi command")
	local a = px.turn.files["/src/pi/a.ts"]
	equal(#a.hunks .. " " .. a.added .. " " .. a.removed, "2 2 1", "pi's diff as hunks")
	equal(a.hunks[1].oldStart .. " " .. a.hunks[1].newStart .. " " .. a.hunks[2].newStart, "9 9 40", "pi's line numbers")
	equal(px.turn.files["/src/pi/b.md"].created, true, "a written file")
	local pi_out = P.info_lines(px, 60, { now = os.time() })
	has(plain(pi_out), "Keep the old API?", "pi's question waits in Open")
	has(table.concat(pi_out, "\n"), P.themes.pi.accent, "pi uses its own palette")
	P.record(px, msg({ role = "user", content = { { type = "text", text = '<skill name="review" location="/x">body</skill>' } } }))
	equal(next(px.waiting), nil, "an answer ends the question")
	equal(px.prompts[#px.prompts].text, "/skill:review", "a skill by its name")
	P.record(px, msg({ role = "assistant", model = "claude-x", stopReason = "stop", content = { { type = "text", text = "Done." } } }))
	equal(px.last_text.text, "Done.", "pi reply")
	local raw = {}
	for _, r in ipairs(lines) do
		raw[#raw + 1] = rex.json.encode(r)
	end
	raw[#raw + 1] = rex.json.encode(msg({ role = "user", content = { { type = "text", text = "more" } } }))
	raw[#raw + 1] = rex.json.encode(msg({ role = "assistant", content = { { type = "text", text = "Done." } } }))
	local turns = P.parsers.pi.turns(raw, 5)
	equal(turns[1], "Done.", "pi turns")
end
-- OpenCode: the copy agents/opencode.lua writes, read through its parser.
do
	local patch = "--- a/a.go\n+++ b/a.go\n@@ -3,2 +3,2 @@\n keep\n-old\n+new\n"
	local lines = {
		{ type = "user", seq = 1, data = { text = "Fix it", time = { created = 1763829615000 } }, parts = {} },
		{ type = "assistant", seq = 2, data = { model = { id = "big", variant = "high" }, tokens = { input = 50, cache = { read = 950, write = 0 } },
			time = { created = 1763829616000, completed = 1763829620000 } }, parts = {
			{ type = "tool", id = "t1", name = "shell", state = { status = "completed", input = { command = "go test ./..." }, metadata = { exit = 0 } } },
			{ type = "tool", id = "t2", name = "shell", state = { status = "completed", input = { command = "go vet" }, metadata = { exit = 1 } } },
			{ type = "tool", id = "t3", name = "edit", state = { status = "completed", input = { path = "/src/oc/a.go" },
				metadata = { files = { { file = "/src/oc/a.go", patch = patch, status = "modified" } } } } },
			{ type = "tool", id = "t4", name = "write", state = { status = "completed", input = { path = "/src/oc/n.md", content = "x\ny\n" } } },
		} },
		{ type = "question", seq = 2, id = "q1", data = { id = "q1", name = "question", state = { status = "running", input = { questions = { { question = "Colour?" } } } } } },
	}
	local ox = P.new_state("opencode")
	for _, r in ipairs(lines) do
		P.record(ox, r)
	end
	equal(ox.prompts[1].text, "Fix it", "opencode prompt")
	equal(ox.model .. " " .. ox.effort .. " " .. ox.context, "big high 1000", "opencode model, variant and context")
	equal(ox.failures[1].command, "go vet", "a failed opencode command")
	local f = ox.turn.files["/src/oc/a.go"]
	equal(f.added .. " " .. f.removed, "1 1", "opencode's patch as hunks")
	equal(ox.turn.files["/src/oc/n.md"].created, true, "a written file")
	local oc_out = P.info_lines(ox, 60, { now = os.time() })
	has(plain(oc_out), "Colour?", "opencode's question waits in Open")
	has(table.concat(oc_out, "\n"), P.themes.opencode.accent, "opencode uses its own palette")
	P.record(ox, { type = "user", seq = 3, data = { text = "blue" }, parts = {} })
	equal(next(ox.waiting), nil, "an answer ends the question")
	P.record(ox, { type = "assistant", seq = 4, data = { model = { id = "big" }, time = { created = 1, completed = 2 } },
		parts = { { type = "text", text = "Blue it is." } } })
	equal(ox.last_text.text, "Blue it is.", "opencode reply")
	equal(P.parsers.opencode.turns({ rex.json.encode(lines[1]), rex.json.encode({ type = "assistant", parts = { { type = "text", text = "Ok" } } }) }, 3)[1], "Ok", "opencode turns")
end
-- The Tasks tab, on made-up tasks, with its state file beside the throwaway
-- settings.json. No provider runs: the writes stay queued.
do
	local tab = P.plugins.Tasks.tab
	local lib, state = tab.lib, tab.state
	local state_file = panel_base .. "tasks_state.json"
	local spawn, run = P.spawn, P.run
	P.spawn, P.run = function() return true end, function() end
	local function strip(s)
		return (s:gsub("\27%[[%d;?]*%a", ""))
	end
	local function write_state(s)
		local f = assert(io.open(state_file, "wb"))
		f:write(rex.json.encode(s))
		f:close()
		tab.activate()
	end
	equal(P.panel.hidden_tabs.Tasks, true, "Tasks is hidden by default")
	equal(P.panel.hidden_tabs.Reminders, true, "Reminders is hidden by default")
	write_state({ provider = "google" })

	local today = "2026-11-21"
	state.clock = today

	-- Titles and typed values.
	local p = lib.parse_title("A. Write the report (1h30)")
	equal(p.rating, "A", "rating prefix")
	equal(p.name, "Write the report", "name without prefix and estimate")
	equal(p.estimate, 90, "estimate suffix")
	equal(lib.parse_title("Taxes (2025)").estimate, nil, "a year is not an estimate")
	equal(lib.parse_title("Taxes (2025)").name, "Taxes (2025)", "a year stays in the name")
	equal(lib.parse_title("C. Walk (30m)").estimate, 30, "minutes suffix")
	equal(lib.compose_title("B", "Walk", 120), "B. Walk (2h)", "title from parts")
	equal(lib.compose_title(nil, "Walk", nil), "Walk", "title without rating and estimate")
	equal(lib.normal_title("A. Swim (1h)"), "swim", "normal title")
	equal(lib.parse_title("Call \226\128\170123 4567\226\128\172").name, "Call 123 4567", "directional marks removed")
	equal(lib.parse_estimate("1h30"), 90, "1h30")
	equal(lib.parse_estimate("1.5h"), 90, "1.5h")
	equal(lib.parse_estimate("45"), 45, "bare minutes")
	equal(lib.parse_estimate("0m"), nil, "zero")
	equal(lib.parse_estimate("soon"), nil, "not an estimate")
	equal(lib.format_minutes(85), "1h25", "1h25")
	equal(lib.format_minutes(120), "2h", "2h")
	equal(lib.parse_date("mon", today), "2026-11-23", "next Monday")
	equal(lib.parse_date("saturday", today), "2026-11-28", "same weekday is next week")
	equal(lib.parse_date("tomorrow", today), "2026-11-22", "tomorrow")
	equal(lib.parse_date("+10", today), "2026-12-01", "plus days across a month")
	equal(lib.parse_date("2026-12-01", today), "2026-12-01", "ISO date")
	equal(lib.parse_date("2026-02-30", today), nil, "impossible date")
	equal(lib.parse_date("", today), "", "empty clears")
	equal(lib.parse_date("soon", today), nil, "not a date")
	local title, due = lib.parse_entry("A. Call the bank (20m) fri", today)
	equal(title, "A. Call the bank (20m)", "entry title")
	equal(due, "2026-11-27", "entry date")
	title, due = lib.parse_entry("Friday", today)
	equal(title, "Friday", "a one-word entry keeps its word")
	equal(due, nil, "a one-word entry has no date")
	equal(lib.due_label("2026-11-19", today), "2d past", "past due label")
	equal(lib.due_label("2026-11-23", today), "Mon 23", "weekday label")
	equal(lib.due_label("2026-12-10", today), "10 Dec", "far label")

	-- A made-up list: Swim was completed once and is open again, and Piano
	-- practice was completed twice.
	local function fixture()
		return { {
			id = "L", title = "To Do",
			tasks = {
				{ id = "swim", title = "A. Swim", due = "2026-11-23" },
				{ id = "piano", title = "A. Piano practice", due = "2026-11-21" },
				{ id = "reply", title = "A. Reply to the landlord", due = "2026-11-19" },
				{ id = "report", title = "A. Write the report", due = "2026-11-12" },
				{ id = "photos", title = "B. Sort the photos", due = "2026-12-10" },
				{ id = "course", title = "B. Sign up for a course", due = "" },
				{ id = "refund", title = "C. Ask for a refund", due = "2026-11-30" },
				{ id = "site", title = "A. Build the club website", due = "2026-11-10" },
				{ id = "move", title = "B. Plan the move", due = "2026-12-01" },
				{ id = "s0", title = "Swim", due = "2026-11-18", status = "completed", completed = "2026-11-18" },
				{ id = "j1", title = "A. Piano practice (10m)", due = "2026-11-20", status = "completed", completed = "2026-11-20" },
				{ id = "j2", title = "A. Piano practice", due = "2026-11-19", status = "completed", completed = "2026-11-19" },
				{ id = "dentist", title = "A. Go to the dentist", status = "completed", completed = "2026-11-21" },
				{ id = "old", title = "B. Old thing", notes = "Dropped in review", status = "completed", completed = "2026-11-21" },
			},
		} }
	end

	local m = lib.model(fixture(), today, {})
	equal(m.by.swim.recurring, true, "completed once and open again is recurring")
	equal(m.by.piano.recurring, true, "completed twice is recurring")
	equal(m.by.reply.recurring, false, "one-off task")
	equal(#m.done, 1, "done today leaves out dropped tasks")
	local today_items = lib.today_items(m)
	equal(#today_items, 4, "four tasks due by today")
	equal(lib.next_item(m).id, "piano", "Next: first A task due by today in the provider's order")
	equal(m.by.report.late, 9, "days past due")
	equal(lib.load(m, today_items, 5), 15 + 3 * 72, "today load: recurring 15m, one-off 72m each")
	equal(lib.load(m, lib.a_items(m), 3), 360, "A load leaves out recurring tasks")
	local items = lib.attention(m, true, {})
	equal(#items, 3, "review, and two slipping A tasks")
	equal(items[1].text, "Daily review due · press v", "review prompt first")
	equal(items[2].id, "report", "slipping task in A, then the provider's order")
	equal(#lib.attention(m, false, { review = today, ["slip report"] = today }), 1, "snoozed items left out")
	equal(#lib.late_items(m), 3, "review walks the late one-off tasks")
	equal(lib.late_items(m)[1].id, "reply", "late tasks in the provider's order within A")

	-- History without the Piano practice completions: Swim completed once under
	-- an older title and open again, Piano practice never completed.
	do
		local lists = fixture()
		local kept = {}
		for _, t in ipairs(lists[1].tasks) do
			if t.id ~= "j1" and t.id ~= "j2" then
				kept[#kept + 1] = t
			end
		end
		lists[1].tasks = kept
		local real = lib.model(lists, today, {})
		equal(real.by.swim.recurring, true, "Swim: completed once and open again")
		equal(real.by.piano.recurring, false, "Piano practice: no completions, not detected")
	end

	-- A provider that knows recurrence marks the task itself.
	do
		local lists = fixture()
		lists[1].tasks[5].recurring = true
		equal(lib.model(lists, today, {}).by.photos.recurring, true, "recurring from the provider")
	end

	-- Steps: Next shows the first open step; estimates come from the steps.
	local lists = fixture()
	table.insert(lists[1].tasks, 9, { id = "s1", title = "Run the build (40m)", parent = "site" })
	table.insert(lists[1].tasks, 10, { id = "s2", title = "Fix login crash (2h)", parent = "site" })
	lists[1].tasks[2].due = "2026-11-22"
	lists[1].tasks[3].due = "2026-11-22"
	lists[1].tasks[4].due = "2026-11-22"
	m = lib.model(lists, today, {})
	local step, parent = lib.next_item(m)
	equal(step.id, "s1", "Next is the first open step")
	equal(parent.id, "site", "with its task")
	equal(lib.remaining(m, m.by.site), 160, "remaining from step estimates")
	equal(lib.too_large(m, m.by.site), false, "a task with steps is not too large")

	-- Overload by estimates.
	lists = fixture()
	lists[1].tasks[3].title = "A. Reply to the landlord (5h)"
	lists[1].tasks[4].title = "A. Write the report (2h)"
	m = lib.model(lists, today, {})
	local keys = {}
	for _, it in ipairs(lib.attention(m, false, {})) do
		keys[#keys + 1] = it.key
	end
	equal(table.concat(keys, ","), "slip report,slip site,today load,A load,split reply", "overload and split by estimates")

	-- Size and the actions offered.
	do
		local lists = fixture()
		lists[1].tasks[3].title = "A. Reply to the landlord (2h30)"
		lists[1].tasks[4].title = "A. Write the report (2h)"
		local sized = lib.model(lists, today, {})
		equal(lib.too_large(sized, sized.by.reply), true, "more than 2h is too large")
		equal(lib.too_large(sized, sized.by.report), false, "2h is not too large")
		local function keys_of(it)
			local out = {}
			for _, a in ipairs(lib.actions(sized, it)) do
				out[#out + 1] = a[1]
			end
			return table.concat(out)
		end
		equal(keys_of(sized.by.reply), "sdx", "a large task: split, new date, done")
		equal(keys_of(sized.by.report), "tdx", "a late task: today, new date, done")
		equal(keys_of(sized.by.course), "ex", "a task without estimate: estimate, done")
		equal(keys_of(sized.by.piano), "x", "a recurring task due today: done")
	end

	-- Streak.
	equal(lib.finish_review({ last = "2026-11-20", streak = 4 }, today).streak, 5, "streak grows after yesterday")
	equal(lib.finish_review({ last = "2026-11-18", streak = 4 }, today).streak, 1, "streak restarts after a gap")
	equal(lib.streak({ last = "2026-11-19", streak = 4 }, today), 0, "streak shown as 0 after a missed day")

	-- Drawing: no line wider than the pane, at 34, 40, 48 and 80 columns.
	state.lists = fixture()
	state.key_day = today
	local function check_view(view, cols)
		state.view = view
		local v = tab.view(cols)
		for _, group in ipairs({ v.pinned or {}, v.lines }) do
			for i, l in ipairs(group) do
				if P.width(l) > cols then
					equal(P.width(l), cols, view .. " line " .. i .. " at " .. cols .. " columns: " .. strip(l))
				end
			end
		end
		return v
	end
	for _, cols in ipairs({ 34, 40, 48, 80 }) do
		for _, view in ipairs({ "now", "today", "all" }) do
			check_view(view, cols)
		end
	end
	local text = {}
	for _, l in ipairs(check_view("now", 47).lines) do
		text[#text + 1] = strip(l)
	end
	text = table.concat(text, "\n")
	equal(text:find("Piano practice ↻", 1, true) ~= nil, true, "recurring mark")
	equal(text:find("Daily review due · press v", 1, true) ~= nil, true, "review prompt shown after a key today")
	equal(text:find("1 of 5 done", 1, true) ~= nil, true, "progress counts done today")

	-- A prompt to Claude today shows the review prompt without a key in the tab.
	state.lists, state.key_day = fixture(), nil
	P.panel.state = P.new_state()
	equal(tab.badge(), "4!", "badge alerts for the slipping tasks")
	equal(#lib.attention(lib.model(state.lists, today, {}), false, {}), 2, "no review prompt before activity")
	state.view = "now"
	local before = table.concat(tab.view(47).lines, "\n")
	equal(before:find("Daily review due", 1, true), nil, "no prompt without activity")
	P.feed(P.panel.state, rex.json.encode({ type = "user", timestamp = "2026-11-21T12:00:00.000Z", message = { content = "Check the build" } }) .. "\n")
	local after = table.concat(tab.view(47).lines, "\n")
	equal(after:find("Daily review due · press v", 1, true) ~= nil, true, "prompt after a prompt to Claude today")
	state.key_day = today

	-- The A stage: three one-off A tasks of 2h30 exceed a day; B moves one out.
	state.lists = fixture()
	for _, t in ipairs(state.lists[1].tasks) do
		if t.id == "reply" or t.id == "report" or t.id == "site" or t.id == "piano" then
			t.title = t.title .. " (2h30)"
		end
	end
	tab.key("v")
	tab.key("a")
	equal(state.input.advance, false, "adding a task does not decide the review's task")
	tab.key("escape")
	equal(state.review.index, 1, "escape from add keeps the review's task")
	tab.key("s")
	tab.key("\r")
	equal(state.review.index, 1, "an empty steps prompt keeps the review's task")
	tab.key("]")
	tab.key("]")
	tab.key("]")
	equal(state.review.stage, "limit", "A work over a day opens the A stage")
	for _, cols in ipairs({ 40, 80 }) do
		check_view("review", cols)
	end
	local first = state.selected
	tab.key("B")
	equal(lib.model(state.lists, today, {}).by[first].rating, "B", "B re-rates in the A stage")
	equal(state.review.stage, "limit", "re-rating stays in the A stage")
	tab.key("\r")
	equal(state.review.stage, "today", "Enter continues to today")
	tab.key("escape")
	equal(state.review, nil, "escape leaves the review")

	-- The Now view selects the Next task; Enter on Attention selects its task;
	-- ? shows all keys.
	state.lists, state.view, state.review, state.selected, state.attention = fixture(), "now", nil, nil, 1
	local shown = strip(table.concat(tab.view(80).lines, "\n"))
	equal(state.selected, "piano", "Now selects the Next task")
	equal(shown:find("Piano practice:  x done", 1, true) ~= nil, true, "footer shows the selected task's actions")
	equal(shown:find("A B C rate", 1, true), nil, "no list of every key in the Now view")
	tab.key("z")
	tab.key("\r")
	equal(state.selected, "report", "Enter selects the Attention item's task")
	has(shown, "z hide until tomorrow · ] next", "the review prompt's keys")
	has(shown, "? keys", "the footer names the key list")
	has(strip(table.concat(tab.view(80).lines, "\n")), "z hide until tomorrow · ] next · Enter go to task", "a warning's keys")
	tab.key("?")
	local keys_now = strip(table.concat(tab.view(80).lines, "\n"))
	for _, part in ipairs({ "Task", "x      mark the task done", "Warnings", "z      hide this warning until tomorrow",
		"Enter  go to the task it is about", "Views", "V      switch between Now, Today and All" }) do
		has(keys_now, part, "the key list in the Now view")
	end
	hasnt(keys_now, "skip to the next task", "no review keys outside the review")
	for _, cols in ipairs({ 34, 48 }) do
		check_view("now", cols)
	end
	state.view = "now"
	tab.key("escape")
	equal(state.help, false, "Esc closes the key list")
	state.view = "all"
	tab.key("?")
	hasnt(strip(table.concat(tab.view(80).lines, "\n")), "Warnings", "no warning keys where no warning shows")
	tab.key("?")

	-- A key that does nothing on the screen shown says so.
	equal(tab.key("z"), true, "z in the All view is answered")
	has(strip(table.concat(tab.view(80).pinned, "\n")), "z hides warnings; use d to move a task to a later date.", "z explains itself")
	tab.key("j")
	equal(state.key_notice, nil, "the next key clears the notice")
	tab.key("y")
	has(state.key_notice, "there is none here", "y without a report")
	state.view = "now"

	-- Review keys, without running the client: the writes stay queued.
	state.lists = fixture()
	state.view = "now"
	tab.key("v")
	equal(state.view, "review", "v starts the review")
	equal(state.review.stage, "late", "late tasks first")
	for _, cols in ipairs({ 34, 40, 48, 80 }) do
		check_view("review", cols)
	end
	tab.key("t")
	equal(state.review.index, 2, "t plans the task for today and moves on")
	equal(lib.model(state.lists, today, {}).by.reply.due, today, "planned for today at once")
	tab.key("-")
	equal(state.review.confirm, true, "drop asks first")
	tab.key("n")
	equal(state.review.confirm, false, "another key keeps the task")
	tab.key("d")
	for ch in ("+3"):gmatch(".") do
		tab.key(ch)
	end
	tab.key("\r")
	equal(lib.model(state.lists, today, {}).by.report.due, "2026-11-24", "new date from the input")
	equal(state.review.index, 3, "a new date moves on")
	tab.key("-")
	tab.key("y")
	equal(lib.model(state.lists, today, {}).by.site, nil, "dropped task leaves the list")
	local dropped
	for _, t in ipairs(state.lists[1].tasks) do
		if t.id == "site" then
			dropped = t
		end
	end
	equal(dropped.status .. " " .. dropped.notes, "completed Dropped in review", "dropped: completed with a note")
	equal(state.review.stage, "today", "A work within a day skips the A stage")
	check_view("review", 47)
	tab.key("\r")
	equal(state.review, nil, "Enter finishes the review")
	equal(lib.streak(tab.state.saved.review, today), 1, "review recorded with a streak")

	-- A provider that is not set up, or whose sign-in ended, says what to do next.
	do
		local lists, spawned = state.lists, {}
		local answers = {}
		P.run = function()
			return table.remove(answers, 1)
		end
		P.spawn = function(name, f)
			spawned[#spawned + 1] = name
			if name == "tasks login" then
				f()
			end
			return true
		end
		local function fetch_with(r)
			answers[#answers + 1] = r
			state.fetched_at = nil
			tab.refresh()
		end
		local function shown(cols)
			local v = tab.view(cols)
			local text = {}
			for _, l in ipairs(v.pinned) do
				text[#text + 1] = strip(l)
			end
			for _, l in ipairs(v.lines) do
				local plain = strip(l)
				equal(P.width(plain) <= cols, true, "the hint fits " .. cols .. " columns: " .. plain)
				text[#text + 1] = plain
			end
			return table.concat(text, "\n")
		end
		fetch_with({ ok = false, code = 4, stdout = '{"error":"setup_required"}\n', stderr = "Google Tasks is not set up yet.\n" })
		equal(state.setup_needed, true, "exit code 4: not set up")
		for _, cols in ipairs({ 34, 47, 80 }) do
			local text = shown(cols)
			has(text, "Google Tasks is not set up", "the tab names the missing setup")
			has(text:gsub("\n", " "), "set up the sidecar Tasks tab", "the tab names what to ask Claude Code")
			has(text:gsub("\n", " "), "the Reminders tab needs no setup", "the tab points to Reminders")
		end
		equal(tab.badge(), nil, "no badge while not set up")
		local missing = { ok = false, code = 4, stdout = '{"error":"setup_required"}\n',
			stderr = "Google Tasks is not set up yet: no OAuth client is stored. Ask Claude Code to set it up.\n" }
		answers = { missing, missing }
		equal(tab.key("L"), true, "L tries the sign-in while not set up")
		equal(spawned[1], "tasks login", "the sign-in runs in the background")
		equal(state.setup_needed, true, "still not set up without a client")
		has(shown(34):gsub("\n", " "), "no OAuth client is stored", "the failed sign-in's error shows below the hint")
		fetch_with({ ok = false, code = 1, stdout = "", stderr = "Google Tasks answered HTTP 403: the API is disabled\n" })
		equal(state.setup_needed, false, "another error replaces the setup notice")
		has(state.fetch_notice, "HTTP 403", "the other error is shown")
		fetch_with(missing)

		fetch_with({ ok = false, code = 3, stdout = '{"error":"auth_required","detail":"sign-in expired"}\n' })
		equal(state.setup_needed, false, "a sign-in answer clears the setup notice")
		equal(state.signed_out, true, "exit code 3: signed out")
		has(shown(47):gsub("\n", " "), "every 7 days", "an ended sign-in names the 7-day limit")
		answers = {
			{ ok = false, code = 1, stdout = "Browser opened for sign-in. Waiting up to 5 minutes.\n",
				stderr = "Sign-in failed: access denied. Add your Google account under Test users.\n" },
			{ ok = false, code = 3, stdout = '{"error":"auth_required","detail":"not signed in"}\n' },
		}
		equal(tab.key("L"), true, "L signs in")
		equal(state.fetch_notice, "Sign-in failed: access denied. Add your Google account under Test users.",
			"a failed sign-in shows the provider's error")
		has(shown(34):gsub("\n", " "), "Sign-in failed: access denied. Add your Google account", "the failure is shown whole, wrapped")
		equal(shown(80):find("7 days", 1, true), nil, "no 7-day note before the first sign-in")

		state.lists, state.signed_out, state.sign_in_detail, state.fetch_notice = lists, false, nil, nil
		P.spawn, P.run = function() return true end, function() end
	end

	-- The settings of the single Tasks tab of earlier versions move to the tab
	-- of the provider it used.
	do
		local base = (assert(real.exec({ "/usr/bin/mktemp", "-d" })).stdout:gsub("%s+$", "")) .. "/"
		local providers = dofile(dir .. "task-providers.lua")
		local settings = dofile(dir .. "settings.lua")
		local function put(file, value)
			local f = assert(io.open(base .. file, "wb"))
			f:write(rex.json.encode(value))
			f:close()
		end
		put("tasks_state.json", { provider = "apple", review = { last = "2026-11-20", streak = 4 } })
		put("settings.json", { tabs = { order = { "Changes", "Tasks", "Artifacts" }, hidden = {} } })
		providers.migrate(base, settings)
		equal(providers.read_state(base, "reminders_state.json").review.streak, 4, "Apple's state moves to the Reminders tab")
		equal(io.open(base .. "tasks_state.json", "rb"), nil, "and leaves Google's file free")
		local order, hidden = settings.tabs(base)
		equal(table.concat(order, " "), "Changes Reminders Artifacts", "Reminders takes the Tasks tab's place")
		equal(hidden.Reminders, nil, "and stays shown")
		providers.migrate(base, settings)
		equal(table.concat((settings.tabs(base)), " "), "Changes Reminders Artifacts", "a second run changes nothing")

		put("tasks_state.json", { provider = "google" })
		put("settings.json", { tabs = { order = { "Tasks" }, hidden = { Tasks = true } } })
		providers.migrate(base, settings)
		order, hidden = settings.tabs(base)
		equal(order[1], "Tasks", "Tasks stays in its place")
		equal(hidden.Tasks, true, "hidden as the Tasks tab was")
		equal(providers.read_state(base).provider, "google", "Google's state stays")
		real.exec({ "/bin/rm", "-rf", base })
	end

	-- Claude's report that a task is done waits in Attention for y or n.
	do
		local reported = lib.attention(lib.model(fixture(), today, {}), true, {}, { report = { note = "sent it" } })
		equal(reported[1].text, "Claude reports done: Write the report: sent it", "report first in Attention")
		equal(reported[1].proposal, true, "report is a proposal")
		local f = io.open(state_file, "rb")
		local saved_state = rex.json.decode(f:read("*a"))
		f:close()
		saved_state.proposals = { reply = { note = "replied" }, site = { note = "" } }
		f = io.open(state_file, "wb")
		f:write(rex.json.encode(saved_state))
		f:close()
		tab.activate()
		state.lists, state.view, state.review, state.attention = fixture(), "now", nil, 1
		local shown = strip(table.concat(tab.view(80).lines, "\n"))
		equal(shown:find("Claude reports done: Reply to the landlord: replied", 1, true) ~= nil, true, "report shown")
		equal(shown:find("y mark done", 1, true) ~= nil, true, "y and n offered")
		equal(tab.badge(), "4!", "badge alerts for a report")
		tab.key("y")
		equal(lib.model(state.lists, today, {}).by.reply.done, true, "y marks the task done")
		equal(tab.state.saved.proposals.reply, nil, "the report is settled")
		tab.key("n")
		equal(lib.model(state.lists, today, {}).by.site ~= nil, true, "n keeps the task open")
		equal(tab.state.saved.proposals.site, nil, "the rejected report is removed")
	end

	-- Done keeps the selection on the row that takes the task's place.
	state.lists, state.view, state.review = fixture(), "now", nil
	state.selected = "reply"
	tab.key("x")
	equal(state.selected, "report", "the next row is selected after x")

	-- Steps input adds subtasks under the task.
	state.lists = fixture()
	state.view = "all"
	state.selected = "course"
	tab.key("s")
	for ch in ("Find the course (20m)"):gmatch(".") do
		tab.key(ch)
	end
	tab.key("\r")
	for ch in ("Pay (10m)"):gmatch(".") do
		tab.key(ch)
	end
	tab.key("\r")
	tab.key("escape")
	m = lib.model(state.lists, today, {})
	equal(#(m.steps.course or {}), 2, "two steps added")
	equal(m.steps.course[1].name, "Find the course", "steps in the order typed")
	equal(lib.remaining(m, m.by.course), 30, "steps give the estimate")

	-- The task actions, with the provider's answers made up.
	local actions, calls, answers = {}, {}, {}
	rex = setmetatable({
		action = function(a)
			actions[a.name] = a
		end,
		exec = function(argv)
			calls[#calls + 1] = argv
			return table.remove(answers, 1)
		end,
	}, { __index = real })
	REX_SIDECAR_TEST_BASE = panel_base
	assert(loadfile(dir .. "task-actions.lua"))(dir)
	REX_SIDECAR_TEST_BASE = nil
	local function fails(name, args, part)
		local ok, err = pcall(actions[name].run, {}, args)
		equal(ok, false, name .. " fails")
		has(tostring(err), part, name .. " error")
	end
	-- Only a shown tab's provider is asked; the tab settings are made up here
	-- and put back after.
	local settings_file = panel_base .. "settings.json"
	local f = io.open(settings_file, "rb")
	local settings_before = f and f:read("*a")
	if f then
		f:close()
	end
	local function show_tabs(...)
		local order = { ... }
		local out = assert(io.open(settings_file, "wb"))
		out:write(rex.json.encode({ tabs = { order = #order > 0 and order or { "Changes" }, hidden = {} } }))
		out:close()
	end
	local apple_file = panel_base .. "reminders_state.json"
	local function apple_state()
		local af = io.open(apple_file, "rb")
		local value = af and rex.json.decode(af:read("*a")) or {}
		if af then
			af:close()
		end
		return value
	end
	local listed = rex.json.encode({ { id = "L", title = "To Do", tasks = { { id = "t1", title = "A. Water the plants", due = "" } } } })
	local apple_listed = rex.json.encode({
		{ id = "R1", title = "Home", tasks = { { id = "r1", title = "Fix the tap", priority = "B", due = "" } } },
		{ id = "R2", title = "Hidden", tasks = { { id = "r2", title = "Secret", due = "" } } },
	})
	write_state({})
	show_tabs()
	fails("tasks_list", {}, "No task tab is shown")
	show_tabs("Tasks")
	answers[1] = { ok = false, code = 3, stdout = "" }
	fails("tasks_list", {}, "Sign-in needed: press L in the Tasks tab")
	equal(calls[#calls][1], dir .. "providers/google-tasks", "the provider beside the extension")
	answers[1] = { ok = false, code = 4, stdout = '{"error":"setup_required"}\n', stderr = "Google Tasks is not set up yet: no OAuth client is stored.\n" }
	fails("tasks_list", {}, "Google Tasks is not set up: Google Tasks is not set up yet")
	fails("tasks_add", { title = "A. Water the plants" }, "due date is required")
	fails("tasks_add", { title = "Water the plants", due = "today" }, "must start with a rating")
	fails("tasks_add", { title = "A. Water the plants", due = "soon" }, "today, tomorrow or YYYY-MM-DD")
	fails("tasks_add", { title = "A. Water the plants", due = "today", provider = "outlook" }, "google or apple")
	answers[1] = { ok = true, code = 0, stdout = listed }
	answers[2] = { ok = true, code = 0, stdout = '{"id":"t2"}' }
	local added = actions.tasks_add.run({}, { title = "B. Mend the fence (2h)", due = "2026-12-01" })
	equal(added.id .. " " .. added.list .. " " .. added.provider, "t2 L google", "tasks_add returns the new task")
	equal(table.concat(calls[#calls], " ", 2), "add L --due 2026-12-01 B. Mend the fence (2h)", "tasks_add arguments")
	local saved = rex.json.decode(assert(io.open(state_file, "rb")):read("*a"))
	equal(type(saved.changed_at), "number", "tasks_add records the change for the tab")
	answers[1] = { ok = true, code = 0, stdout = listed }
	fails("tasks_report_done", { id = "t9" }, "No open task with ID t9")
	answers[1] = { ok = true, code = 0, stdout = listed }
	equal(actions.tasks_report_done.run({}, { id = "t1", note = "watered" }).title, "A. Water the plants", "the report names the task")
	saved = rex.json.decode(assert(io.open(state_file, "rb")):read("*a"))
	equal(saved.proposals.t1.note, "watered", "the report waits in the state file")

	-- Both tabs shown: both providers are listed, without a hidden Reminders
	-- list, and each task carries its rating.
	show_tabs("Tasks", "Reminders")
	local af = assert(io.open(apple_file, "wb"))
	af:write(rex.json.encode({ hidden_lists = { R2 = true }, default_list = "R1" }))
	af:close()
	answers[1] = { ok = true, code = 0, stdout = listed }
	answers[2] = { ok = true, code = 0, stdout = apple_listed }
	local all = actions.tasks_list.run({}, {})
	equal(#all, 2, "a list from each provider, the hidden one left out")
	equal(all[1].provider .. " " .. all[2].provider, "google apple", "each list names its provider")
	equal(all[1].tasks[1].rating .. all[2].tasks[1].rating, "AB", "the rating from the title or the priority")
	equal(calls[#calls][1], dir .. "providers/apple-reminders", "Reminders asked too")

	-- An ended Google sign-in doesn't hide the Reminders tasks.
	answers[1] = { ok = false, code = 3, stdout = "" }
	answers[2] = { ok = true, code = 0, stdout = apple_listed }
	all = actions.tasks_list.run({}, {})
	equal(#all .. " " .. all[1].provider, "1 apple", "Reminders listed while Google fails")
	answers[1] = { ok = false, code = 3, stdout = "" }
	answers[2] = { ok = false, code = 3, stdout = "" }
	fails("tasks_list", {}, "Sign-in needed: press L in the Tasks tab")

	-- With only Reminders shown, a task goes to its default list, its rating
	-- to the priority field.
	show_tabs("Reminders")
	answers[1] = { ok = true, code = 0, stdout = '{"id":"r3"}' }
	added = actions.tasks_add.run({}, { title = "A. Call the plumber (15m)", due = "2026-12-02" })
	equal(added.provider .. " " .. added.list, "apple R1", "the Reminders default list")
	equal(table.concat(calls[#calls], " ", 2), "add R1 --due 2026-12-02 --priority A Call the plumber (15m)", "the rating as a priority")
	fails("tasks_add", { title = "Step", due = "today", parent = "r1" }, "Reminders has no steps")
	answers[1] = { ok = true, code = 0, stdout = apple_listed }
	equal(actions.tasks_report_done.run({}, { id = "r1", note = "fixed" }).provider, "apple", "the report finds the Reminders task")
	equal(apple_state().proposals.r1.note, "fixed", "and waits in the Reminders state file")
	os.remove(apple_file)
	if settings_before then
		local out = assert(io.open(settings_file, "wb"))
		out:write(settings_before)
		out:close()
	else
		os.remove(settings_file)
	end
	rex = real
	P.spawn, P.run = spawn, run
end
-- The Reminders tab: the rating in the priority field, the lists shown, the
-- default list for new tasks, and moving a task. The background work runs
-- at once and the provider calls are recorded.
do
	local tab = P.plugins.Reminders.tab
	local lib, state = tab.lib, tab.state
	local state_file = panel_base .. "reminders_state.json"
	local spawn, run = P.spawn, P.run
	local calls = {}
	P.spawn = function(_, fn)
		fn()
		return true
	end
	P.run = function(argv)
		calls[#calls + 1] = table.concat(argv, " ", 2)
		if argv[2] == "move" then
			return { ok = true, code = 0, stdout = '{"id":"moved-1"}\n' }
		elseif argv[2] == "add" then
			return { ok = true, code = 0, stdout = '{"id":"new-1"}\n' }
		elseif argv[2] == "tasks" then
			return { ok = false, code = 1, stdout = "", stderr = "offline\n" }
		end
		return { ok = true, code = 0, stdout = "updated\n" }
	end
	local function saved_state()
		local f = assert(io.open(state_file, "rb"))
		local s = rex.json.decode(f:read("*a"))
		f:close()
		return s
	end
	local f = assert(io.open(state_file, "wb"))
	f:write(rex.json.encode({ proposals = { a1 = { note = "swam" } }, snoozed = { ["slip a1"] = "2026-11-21" } }))
	f:close()
	tab.activate()
	state.clock = "2026-11-21"
	state.lists = {
		{ id = "L1", title = "Personal", tasks = {
			{ id = "a1", title = "Swim", priority = "A", due = "2026-11-21" },
			{ id = "b1", title = "B. Old prefix", due = "2026-11-21" },
			{ id = "c1", title = "Plan the trip (1h)", priority = "C", due = "" },
			{ id = "d1", title = "Renew the passport (3h)", priority = "B", due = "2026-11-10" },
			{ id = "z1", title = "Water the plants", priority = "C", status = "completed", completed = "2026-11-21" },
		} },
		{ id = "L2", title = "Work", tasks = { { id = "w1", title = "Ship it", priority = "B", due = "2026-11-21" } } },
	}
	state.view = "all"

	local m = lib.model(state.lists, "2026-11-21", {})
	equal(m.by.a1.rating, "A", "the priority field is the rating")
	equal(m.by.b1.rating, "B", "a rating prefix from before still counts")
	equal(m.by.c1.estimate, 60, "the estimate stays in the title")
	has(plain(tab.view(60).lines), "C Plan the trip", "the rating shown as a letter")

	-- Rating sets the priority and takes an old prefix out of the title.
	state.selected = "b1"
	tab.key("A")
	equal(calls[1], "update L1 b1 --title Old prefix --priority A", "A sets High priority")
	equal(lib.model(state.lists, "2026-11-21", {}).by.b1.rating, "A", "shown at once")

	-- No steps: s does nothing, and no split warnings, even for a large task
	-- far past due, nor in the review.
	equal(tab.key("s"), false, "no steps")
	hasnt(plain(tab.view(60).lines), "split", "no split warning")
	tab.key("v")
	has(plain(tab.view(60).lines), "Renew the passport", "the review shows the late task")
	hasnt(plain(tab.view(60).lines), "steps", "and says nothing of steps")
	tab.key("escape")
	state.view, state.selected = "all", "b1"
	tab.key("?")
	hasnt(plain(tab.view(60).lines), "split it into steps", "no steps in the keys")
	has(plain(tab.view(60).lines), "move it to another list", "m in the keys")
	tab.key("?")

	-- l: hide a list, refuse to hide the last, and choose the default one.
	tab.key("l")
	equal(state.picker.kind, "lists", "l opens the lists")
	has(plain(tab.view(60).lines), "✓ Work", "every list shown at first")
	tab.key("j")
	tab.key(" ")
	equal(saved_state().hidden_lists.L2, true, "Work hidden")
	has(plain(tab.view(60).lines), "○ Work", "and marked hidden")
	tab.key("k")
	tab.key(" ")
	equal(saved_state().hidden_lists.L1, nil, "the last shown list stays shown")
	tab.key("j")
	tab.key("d")
	equal(saved_state().default_list, "L2", "Work is the default list")
	equal(saved_state().hidden_lists.L2, nil, "and shown again, so new tasks can be seen")
	has(plain(tab.view(60).lines), "Work ★", "the default marked")
	tab.key(" ")
	equal(saved_state().hidden_lists.L2, true, "Work hidden again")
	tab.key("escape")
	equal(state.picker, nil, "Esc closes the lists")
	equal(lib.model(state.lists, "2026-11-21", {}).by.w1 ~= nil, true, "the model itself keeps every list")
	hasnt(plain(tab.view(60).lines), "Ship it", "a hidden list's tasks aren't shown")

	-- A new task goes to the default list, its rating to the priority field.
	tab.key("a")
	for ch in ("B. Call the bank"):gmatch(".") do
		tab.key(ch)
	end
	tab.key("\r")
	equal(calls[#calls - 1], "add L1 --priority B Call the bank", "a hidden default isn't used: the selected task's list, undated in All")

	-- m moves a task: a copy with a new ID, which the state file follows.
	state.selected = "a1"
	tab.key("m")
	equal(state.picker.kind, "move", "m opens the lists")
	equal(state.picker.index, 1, "starting at the task's own list")
	has(plain(tab.view(60).lines), "Personal  now here", "its list marked")
	tab.key("j")
	tab.key("\r")
	equal(calls[#calls - 1], "move L1 a1 L2", "moved through the provider")
	equal(state.lists[2].tasks[#state.lists[2].tasks].id, "moved-1", "the task takes its new ID")
	equal(saved_state().proposals["moved-1"].note, "swam", "a report follows the task")
	equal(saved_state().snoozed["slip moved-1"], "2026-11-21", "and a hidden warning")
	equal(saved_state().proposals.a1, nil, "nothing left under the old ID")

	-- E edits a task: its title, rating and estimate, and a date when one is
	-- typed last.
	state.view, state.selected = "all", "c1"
	tab.key("E")
	equal(state.input.text, "C. Plan the trip (1h)", "the edit starts from the task")
	state.input.text = "A. Plan the summer trip (2h) +3"
	tab.key("\r")
	equal(calls[#calls - 1], "update L1 c1 --title Plan the summer trip (2h) --due 2026-11-24 --priority A", "the edit, saved")
	state.selected = "c1"
	tab.key("E")
	state.input.text = "A. Plan the summer trip"
	tab.key("\r")
	equal(calls[#calls - 1], "update L1 c1 --title Plan the summer trip --priority A", "no date typed: the date stays")

	-- x on a task done today marks it not done.
	state.view, state.selected = "now", "z1"
	has(plain(tab.view(60).lines), "x not done", "the footer offers it")
	tab.key("x")
	equal(calls[#calls - 1], "update L1 z1 --status needsAction", "not done, through the provider")
	equal(lib.model(state.lists, "2026-11-21", {}).by.z1.done, nil, "open again at once")

	-- An edit or a new task without a name is refused.
	state.view, state.selected = "all", "c1"
	local before = #calls
	tab.key("E")
	state.input.text = "A. (20m)"
	tab.key("\r")
	equal(state.input and state.input.error, "A task needs a name.", "an empty name on edit")
	equal(#calls, before, "nothing saved")
	tab.key("escape")
	tab.key("a")
	state.input.text = "B. (20m) fri"
	tab.key("\r")
	equal(state.input and state.input.error, "A task needs a name.", "an empty name on add")
	tab.key("escape")

	-- D deletes a task after y; another key keeps it.
	state.selected = "c1"
	tab.key("D")
	has(plain(tab.view(60).lines), "Delete Plan the summer trip? It can't be undone.", "D asks first")
	tab.key("n")
	equal(#calls, before, "n keeps the task")
	equal(lib.model(state.lists, "2026-11-21", {}).by.c1 ~= nil, true, "still there")
	tab.key("D")
	tab.key("y")
	equal(calls[#calls - 1], "delete L1 c1", "y deletes it through the provider")
	equal(lib.model(state.lists, "2026-11-21", {}).by.c1, nil, "gone at once")

	-- A blank line between the view switcher and the first box.
	local pinned = tab.view(60).pinned
	equal(pinned[#pinned], "", "space under the switcher")
	equal(plain(tab.view(60).lines):match("^[^\n]*") ~= "", true, "and only one blank line")

	P.spawn, P.run = spawn, run
	os.remove(state_file)
end
-- The Google Tasks provider, with the Keychain made up and no request sent.
do
	local stored = {}
	local requests = {}
	--- What the browser sends back to the sign-in's local port.
	local browser = { request = "" }
	--- Runs the provider with `...` as its arguments; returns its exit code,
	--- standard output and standard error.
	local function provider(...)
		local argv = {}
		for _, a in ipairs({ ... }) do
			argv[#argv + 1] = a .. "\31"
		end
		local out, err = {}, {}
		local exit, write, stderr = os.exit, io.write, io.stderr
		os.exit = function(code)
			error({ exit = code or 0 }, 0)
		end
		io.write = function(...)
			for _, s in ipairs({ ... }) do
				out[#out + 1] = s
			end
		end
		io.stderr = { write = function(_, ...)
			for _, s in ipairs({ ... }) do
				err[#err + 1] = s
			end
		end }
		rex = setmetatable({
			args = { argv = table.concat(argv) },
			exec = function(cmd)
				if cmd[1] == "/usr/bin/security" and cmd[2] == "find-generic-password" then
					local value = stored[cmd[6]]
					return { ok = value ~= nil, code = value and 0 or 44, stdout = value or "", stderr = "" }
				end
				requests[#requests + 1] = cmd
				if cmd[1] == "/bin/sh" and cmd[3]:find("nc -l", 1, true) then
					return { ok = true, code = 0, stdout = browser.request, stderr = "" }
				end
				return { ok = false, code = 1, stdout = "", stderr = "no requests in the test" }
			end,
		}, { __index = real })
		local _, result = pcall(dofile, dir .. "providers/google-tasks.lua")
		os.exit, io.write, io.stderr = exit, write, stderr
		rex = real
		return type(result) == "table" and result.exit or result, table.concat(out), table.concat(err)
	end
	local code, out, err = provider("tasks")
	equal(code, 4, "no client: not set up")
	has(out, "setup_required", "not set up, as JSON")
	has(err, 'Ask Claude Code "set up the sidecar Tasks tab"', "the error names the next step")
	stored.refresh_token = "made-up token"
	equal(provider("tasks"), 4, "a refresh token without a client is not set up")
	stored.refresh_token, stored.client = nil, '{"installed":{"client_id":"id","client_secret":"made-up"}}'
	code, out = provider("tasks")
	equal(code, 3, "a client without a refresh token needs sign-in")
	has(out, '"not signed in"', "sign-in needed, as JSON")
	equal(#requests, 0, "nothing is sent without a sign-in")
	local folder = real.exec({ "mktemp", "-d" }).stdout:gsub("%s+$", "") .. "/"
	local function client_file(text)
		local path = folder .. "client.json"
		local f = assert(io.open(path, "wb"))
		f:write(text)
		f:close()
		return path
	end
	code, _, err = provider("import-client", client_file('{"web":{"client_id":"id"}}'))
	equal(code, 1, "a Web application client is refused")
	has(err, "Create a client of type Desktop app", "the error names the client type")
	code, _, err = provider("import-client", client_file("not JSON"))
	equal(code, 1, "a file that isn't a client is refused")
	has(err, "https://console.cloud.google.com/auth/clients", "the error names where to download the client")
	equal(#requests, 0, "a refused file is not stored")
	os.remove(folder .. "client.json")
	os.remove(folder)
	code, _, err = provider("login")
	equal(code, 1, "no answer from the browser")
	has(err, "no answer from the browser within 5 minutes", "the error names the wait")
	has(err, "Test users at https://console.cloud.google.com/auth/audience", "the error names the likely fix")
	browser.request = "GET /?error=access_denied&state=x HTTP/1.1\r\n"
	code, _, err = provider("login")
	equal(code, 1, "access denied")
	has(err, "access denied. Add your Google account under Test users", "the error names the test user fix")
end
-- Tab plugins: loaded in file name order, each with its keys, clicks and
-- refresh, and with its errors kept to its tab.
do
	local plugin_dir = real.exec({ "mktemp", "-d" }).stdout:gsub("%s+$", "") .. "/"
	local function put(name, text)
		local f = assert(io.open(plugin_dir .. name, "wb"))
		f:write(text)
		f:close()
	end
	put("b-notes.lua", [[
local sidecar = ...
local seen = {}
return {
	name = "Notes",
	interval = 30,
	seen = seen,
	refresh = function()
		seen.refreshed = sidecar.run({ "/bin/echo", "fresh" }).stdout
	end,
	view = function(cols)
		local lines, actions = {}, {}
		sidecar.box(lines, actions, cols, sidecar.colours.teal, "Notes", "", function()
			lines[#lines + 1] = "first"
			actions[#lines] = { kind = "note", id = 1 }
		end)
		return { lines = lines, actions = actions, selected = 2 }
	end,
	key = function(k)
		seen[#seen + 1] = k
		return k == "j"
	end,
	act = function(action)
		seen.acted = action.id
	end,
}
]])
	put("a-broken.lua", "return {")
	put("c-faulty.lua", [[
return {
	name = "Faulty",
	view = function() error("no view") end,
	refresh = function() error("no data") end,
}
]])
	put("d-info.lua", "return { name = 'Info' }")
	put("notes.txt", "not a plugin")
	local tabs = {}
	for i, t in ipairs(P.tabs) do
		tabs[i] = t
	end
	P.load_plugins(plugin_dir)
	equal(table.concat(P.tabs, " ", #tabs + 1), "a-broken.lua Notes Faulty d-info.lua", "plugin tabs follow, by file name")

	local function select(name)
		for i, t in ipairs(P.tabs) do
			if t == name then
				P.key(tostring(i))
			end
		end
		equal(P.current().tab, name, "a digit selects a plugin tab")
	end
	select("Notes")
	local seen = P.plugins.Notes.tab.seen
	P.key("j")
	P.key("k")
	equal(table.concat(seen, " "), "j k", "the open plugin tab hears keys first")
	local view = P.current()
	has(plain(view.lines), "│ first", "the plugin's lines in its box")
	P.act(view.actions[2])
	equal(seen.acted, 1, "a click goes to the plugin")
	P.act({ kind = "tab", tab = "Info" })
	equal(P.current().tab, "Info", "a tab click is the pane's")
	P.key("j")
	equal(#seen, 2, "a plugin hears no keys while its tab is hidden")

	select("a-broken.lua")
	has(plain(P.current().lines), "a-broken.lua", "the load error on the file's tab")
	select("Faulty")
	has(plain(P.current().lines), "no view", "a failing view")
	select("d-info.lua")
	has(plain(P.current().lines), "tab name not yet in use", "a tab name in use")

	-- A refresh runs as a task, and its error becomes the pane's notice.
	P.refresh_plugins(os.clock())
	for _ = 1, 100 do
		P.step_tasks()
		if seen.refreshed then
			break
		end
		rex.sleep(0.02)
	end
	equal(seen.refreshed, "fresh\n", "the refresh ran its command")
	select("Notes")
	has(plain(P.current().pinned), "no data", "a failed refresh, as the notice")
	P.refresh_plugins(os.clock())
	equal(P.spawn("tab Notes", function() end), true, "no refresh before the interval")
	P.step_tasks()

	-- Tab settings: hiding, reordering with J/K, Shift+arrows, and clickable ↑↓, including Info.
	P.key("1")
	P.key(",")
	has(plain(P.current().lines), "✓ Info  always shown", "Info always shows")
	P.key(" ")
	equal(P.panel.hidden_tabs.Info, nil, "Info cannot be hidden")
	P.key("j") -- Changes
	P.key("j") -- Artifacts
	P.key(" ") -- hide Artifacts
	P.key("j") -- Tasks
	P.key("K") -- move Tasks above Artifacts
	has(plain(P.current().lines), "○ Artifacts", "a hidden tab")
	-- Clickable ↑↓ buttons and Shift+arrows reorder tabs too (including Info).
	local tv = P.current()
	local tasks_row
	for line_no, a in pairs(tv.actions) do
		for _, r in ipairs(a.ranges or {}) do
			if r.action.kind == "show_tab" and r.action.name == "Tasks" then
				tasks_row = line_no
			end
		end
	end
	local up_action
	for _, r in ipairs(tv.actions[tasks_row].ranges) do
		if r.action.kind == "move_tab" and r.action.step == -1 then
			up_action = r.action
		end
	end
	equal(up_action ~= nil, true, "clickable ↑ action on movable tab")
	P.act(up_action) -- move Tasks above Changes (now Info, Tasks, Changes, Artifacts, ...)
	P.key("shift_down") -- move Tasks back below Changes (now Info, Changes, Tasks, Artifacts, ...)
	P.key("escape")
	equal(table.concat(P.tabs, " "), "Info Changes a-broken.lua Notes Faulty d-info.lua", "the tabs shown, in order")
	local f = assert(io.open(panel_base .. "settings.json", "rb"))
	local saved = rex.json.decode(f:read("*a"))
	f:close()
	equal(saved.tabs.hidden.Artifacts, true, "the hidden tab, saved")
	equal(saved.tabs.order[3], "Tasks", "the order, saved")
	equal(saved.tabs.hidden.Tasks, true, "a tab hidden by default, saved hidden")
	P.key(",")
	P.key("j") -- Changes
	P.key("j") -- Tasks
	P.key(" ") -- show Tasks
	equal(P.tabs[3], "Tasks", "a tab hidden by default, shown")
	-- Info itself can also be moved down in the tab order.
	P.key("k") -- Changes
	P.key("k") -- Info
	P.key("J") -- move Info to position 2
	equal(P.tabs[1] .. " " .. P.tabs[2], "Changes Info", "Info can be reordered")
	P.key("K") -- move Info back to position 1
	P.key("j")
	P.key("j")
	P.key(" ") -- re-hide Tasks
	P.key("escape")
	P.key("1")
	for i = #P.tabs, 1, -1 do
		P.tabs[i] = tabs[i]
	end
	real.exec({ "rm", "-rf", plugin_dir, panel_base })
end
do
	-- diff-view gives leaf a patch file, removed once leaf exits; REX_LEAF stands
	-- in for leaf, printing its arguments and the patch.
	local tmp = real.exec({ "mktemp", "-d" }).stdout:gsub("%s+$", "")
	local fake = tmp .. "/leaf"
	local f = assert(io.open(fake, "w"))
	f:write('#!/bin/sh\necho "$1 $2"\ncat "$3"\necho "$3" >' .. tmp .. '/patch-path\n')
	f:close()
	real.exec({ "chmod", "+x", fake })
	local patch = tmp .. "/turn.patch"
	f = assert(io.open(patch, "w"))
	f:write("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n")
	f:close()
	local r = real.exec({ "/usr/bin/env", "REX_LEAF=" .. fake, dir .. "diff-view", "patch", patch })
	has(r.stdout, "diff --patch", "leaf reads the diff from a patch file")
	has(r.stdout, "+b", "the whole patch")
	local given = io.open(tmp .. "/patch-path"):read("*l")
	equal(io.open(given, "r"), nil, "leaf's patch file is removed after it exits")
	real.exec({ "rm", "-rf", tmp })

	local L = dofile(dir .. "leaf.lua")
	local home = real.exec({ "mktemp", "-d" }).stdout:gsub("%s+$", "")
	real.exec({ "mkdir", "-p", home .. "/.cargo/bin" })
	real.exec({ "touch", home .. "/.cargo/bin/leaf" })
	local found = L.path(home)
	equal(found == home .. "/.cargo/bin/leaf" or found == "/opt/homebrew/bin/leaf" or found == "/usr/local/bin/leaf", true, "leaf from cargo is found")
	real.exec({ "rm", "-rf", home })

	local base = real.exec({ "mktemp", "-d" }).stdout:gsub("%s+$", "") .. "/"
	local SL = dofile(dir .. "settings.lua")
	equal(SL.leaf_ask(base), true, "leaf is offered by default")
	SL.set_leaf_ask(base, false)
	equal(SL.leaf_ask(base), false, "don't ask again is kept")
	real.exec({ "rm", "-rf", base })
end
return "rex-sidecar: all tests passed"
