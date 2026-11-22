-- Run: rex do ~/.config/rex/extensions/agents/test.lua
-- Fakes sqlite3 and ps, and uses a throwaway folder for Claude Code's files:
-- it doesn't read the real ~/.claude or ~/.codex.
local dir = debug.getinfo(1, "S").source:match("^@?(.*/)")
local A = dofile(dir .. "init.lua")
local U, claude, codex = A.util, A.claude, A.codex

local function equal(actual, expected, what)
	if actual ~= expected then
		error(what .. ": " .. tostring(actual) .. " ~= " .. tostring(expected), 2)
	end
end

local real_exec = U.exec
local real_home = U.home
local queries, rows_for, args_of, etime_of = {}, nil, {}, {}

--- sqlite3 answers with the rows `rows_for(query)` gives; ps with the
--- command lines and ages set for a pid; anything else runs.
U.exec = function(argv)
	if argv[1] == "/usr/bin/sqlite3" then
		queries[#queries + 1] = argv[5]
		local rows = rows_for and rows_for(argv[5]) or {}
		return { ok = true, stdout = #rows > 0 and rex.json.encode(rows) or "" }
	elseif argv[1] == "/bin/ps" then
		local pid = tonumber(argv[#argv])
		if argv[4] == "args=" then
			return { ok = args_of[pid] ~= nil, stdout = (args_of[pid] or "") .. "\n" }
		end
		return { ok = etime_of[pid] ~= nil, stdout = (etime_of[pid] or "") .. "\n" }
	end
	return real_exec(argv)
end

local tmp = real_exec({ "mktemp", "-d" }).stdout:gsub("%s+$", "")

local ok, err = pcall(function()
	-- Which agent a pane runs.
	equal(A.of({ argv0 = "/opt/homebrew/bin/codex" }), codex, "codex by path")
	equal(A.of({ argv0 = "claude" }), claude, "claude by name")
	equal(A.of({ argv0 = "codex-helper" }), nil, "only the program itself")
	equal(A.of(nil), nil, "no process")
	local adapter, p = A.find({ argv0 = "git" }, { { argv0 = "/bin/codex", pid = 9 }, { argv0 = "-zsh" } })
	equal(adapter, codex, "an agent a command runs under")
	equal(p.pid, 9, "its process")
	local _, _, pid = A.in_process({ foreground = { argv0 = "claude", pid = 7 } })
	equal(pid, 7, "the agent's pid")
	equal(A.in_process(nil), nil, "no process call")
	equal(A.find({ argv0 = "nvim" }, {}), nil, "no agent")

	-- Codex titles.
	equal(codex.title_name("Check Hydra domain skill | precog"), "Check Hydra domain skill", "name before the folder")
	equal(codex.title_name("⠴ TAL-185: compare | TAL-185"), "TAL-185: compare", "without a spinner")
	equal(codex.title_name("Name | with | bars | folder"), "Name | with | bars", "only the last bar is the folder's")
	equal(codex.title_name("⠋⠙ Two frames | x"), "Two frames", "a spinner of several frames")
	equal(codex.title_name("é first | x"), "é first", "other leading letters kept")
	equal(codex.title_name("🚀 Launch | x"), "🚀 Launch", "a leading emoji kept")
	local name, cut = codex.title_name("I want to do some hill climbing on [Image #1]... | precog")
	equal(name, "I want to do some hill climbing on [Image #1]", "a cut name's start")
	equal(cut, true, "a cut name")
	equal(select(2, codex.title_name("Whole | x")), false, "a whole name")
	equal(codex.title_name("codex | precog"), nil, "no name yet")
	equal(codex.title_name(nil), nil, "no title")
	equal(codex.resume_id("/x/codex resume 01a1e306-06f5-79d2-8798-94017387b6ca"), "01a1e306-06f5-79d2-8798-94017387b6ca", "resumed thread")
	equal(codex.resume_id("/x/codex"), nil, "a new thread")
	equal(codex.pick_db("state_4.sqlite\nstate_12.sqlite\nstate_5.sqlite-wal\nlogs_2.sqlite\n"), "state_12.sqlite", "newest state database")
	equal(codex.pick_db(""), nil, "no state database")
	equal(codex.window_label(300), "5h", "hours")
	equal(codex.window_label(10080), "7d", "days")
	equal(codex.window_label(90), "90m", "minutes")
	local limits = codex.limits({ primary = { used_percent = 12.5, window_minutes = 300, resets_at = 99 }, secondary = { window_minutes = 10080 } })
	equal(#limits, 1, "limits with a percentage")
	equal(limits[1].label, "5h", "limit label")
	equal(limits[1].used, 12.5, "limit used")
	equal(limits[1].resets_at, 99, "limit reset")

	-- A pane's thread: by title, then resume, then directory and start.
	local row = { id = "t1", rollout_path = "/r/t1.jsonl", cwd = "/src/app", name = "Fix parser", model = "gpt-test", reasoning_effort = "high", created_at = 100 }
	queries = {}
	rows_for = function(q)
		return q:find("name = 'Fix parser' and cwd = '/src/app'", 1, true) and { row } or {}
	end
	equal(codex.find_thread("/db", { pid = 1, cwd = "/src/app", title = "Fix parser | app" }).id, "t1", "by title")
	equal(#queries, 1, "one query for a title")
	equal(queries[1]:find("source not like '{%'", 1, true) ~= nil, true, "top-level threads only")
	equal(queries[1]:find("source <> 'exec'", 1, true) ~= nil, true, "no codex exec runs")
	equal(queries[1]:find("<> 'codex_exec'", 1, true) ~= nil, true, "no codex exec originator")

	queries = {}
	rows_for = function(q)
		return q:find("name = 'Fix parser'", 1, true) and not q:find("cwd =", 1, true) and { row } or {}
	end
	equal(codex.find_thread("/db", { pid = 1, cwd = "/moved", title = "Fix parser | app" }).id, "t1", "a whole name anywhere")

	queries = {}
	rows_for = function(q)
		local here = q:find("cwd = '/elsewhere'", 1, true)
		return (q:find("instr(name, 'Fix par') = 1", 1, true) and not here) and { row } or {}
	end
	equal(codex.find_thread("/db", { pid = 1, cwd = "/elsewhere", title = "Fix par... | app", args = "/x/codex", started = 0 }), nil,
		"the start of a name only in the pane's directory")
	queries = {}
	rows_for = function(q)
		return q:find("instr(name, 'Fix par') = 1 and cwd = '/src/app'", 1, true) and { row } or {}
	end
	equal(codex.find_thread("/db", { pid = 1, cwd = "/src/app", title = "Fix par... | app" }).id, "t1", "by a cut title in its directory")

	queries = {}
	args_of[2] = "/x/codex resume a1b2-aaaa-bbbb-cccc-dddd"
	rows_for = function(q)
		return q:find("id = 'a1b2-aaaa-bbbb-cccc-dddd'", 1, true) and { row } or {}
	end
	equal(codex.find_thread("/db", { pid = 2, cwd = "/src/app", title = "codex | app" }).id, "t1", "by resume")

	queries = {}
	args_of[3] = "/x/codex"
	rows_for = function(q)
		return q:find("cwd = '/src/app' and created_at >= 995", 1, true) and { row } or {}
	end
	equal(codex.find_thread("/db", { pid = 3, cwd = "/src/app", started = 1000 }).id, "t1", "by directory and start")
	rows_for = function(q)
		return q:find("created_at >= 995", 1, true) and { row, row } or {}
	end
	equal(codex.find_thread("/db", { pid = 3, cwd = "/src/app", started = 1000 }), nil, "no guess between two new threads")
	equal(codex.find_thread("/db", { pid = 3 }), nil, "nothing to go on")

	rows_for = function(q)
		return q:find("'it''s'", 1, true) and { row } or {}
	end
	equal(codex.find_thread("/db", { pid = 4, title = "it's | x" }).id, "t1", "quotes in a name")

	-- A session, reused for a few seconds.
	local db = codex.db
	codex.db = function()
		return "/db"
	end
	etime_of[5] = "01:00"
	queries = {}
	rows_for = function(q)
		if q:find("from threads where archived", 1, true) then
			return { row }
		end
		return {}
	end
	local sess = codex.session({ pid = 5, cwd = "/src/app", title = "Fix parser | app" })
	equal(sess.id, "t1", "session id")
	equal(sess.transcript, "/r/t1.jsonl", "session rollout")
	equal(sess.name, "Fix parser", "session name")
	equal(sess.model, "gpt-test", "session model")
	equal(sess.effort, "high", "session effort")
	equal(math.abs(sess.started - (os.time() - 60)) <= 2, true, "uptime from the process")
	local asked = #queries
	codex.session({ pid = 5, cwd = "/src/app", title = "Fix parser | app" })
	equal(#queries, asked, "reused within the cache time")
	codex.session({ pid = 5, cwd = "/src/app", title = "⠴ Fix parser | app" })
	equal(#queries, asked, "reused while the spinner turns")

	-- Subagents run while their thread moves.
	rows_for = function(q)
		if q:find("thread_spawn_edges", 1, true) then
			return {
				{ id = "s1", rollout_path = "/r/s1.jsonl", agent_path = "/root/review_parser", agent_nickname = "Hume", created_at = 10, updated_at = 1000 },
				{ id = "s2", rollout_path = "/r/s2.jsonl", agent_nickname = "Kant", created_at = 20, updated_at = 100 },
			}
		end
		return {}
	end
	local subs = codex.subagents({ id = "t1" }, 1100)
	equal(#subs, 2, "codex subagents")
	equal(subs[1].description, "review parser", "named by its path")
	equal(subs[1].type, "Hume", "its nickname")
	equal(subs[1].running, true, "moved recently")
	equal(subs[2].description, "Kant", "named by its nickname without a path")
	equal(subs[2].running, false, "quiet for long")
	codex.db = db

	-- The account's latest limits, from the end of a rollout.
	local rollout = tmp .. "/rollout.jsonl"
	local f = assert(io.open(rollout, "w"))
	f:write('{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":5,"window_minutes":300}}}}\n')
	f:write('{"type":"event_msg","payload":{"type":"agent_message"}}\n')
	f:write('{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":77,"window_minutes":10080}}}}\n')
	f:write('{"type":"event_msg","payload":{"type":"task_complete"}}\n')
	f:close()
	equal(codex.last_rate_limits(rollout).primary.used_percent, 77, "the last limits")
	equal(codex.last_rate_limits(tmp .. "/none.jsonl"), nil, "no rollout")

	-- Claude: the session file, the transcript, the status line and subagents.
	U.home = tmp
	local config = tmp .. "/.claude"
	real_exec({ "mkdir", "-p", config .. "/sessions", config .. "/projects/-src-app/sid/subagents", config .. "/state/statusline" })
	local function write(path, text)
		local out = assert(io.open(path, "w"))
		out:write(text)
		out:close()
	end
	write(config .. "/sessions/42.json", rex.json.encode({ sessionId = "sid", cwd = "/src/app", startedAt = 5000, status = "busy", name = "fallback" }))
	write(config .. "/projects/-src-app/sid.jsonl", "")
	write(config .. "/state/statusline/sid.json", rex.json.encode({
		session_name = "Panel work",
		model = { id = "claude-test-1-0", display_name = "Test 1.0" },
		effort = { level = "high" },
		context_window = { context_window_size = 200000 },
		rate_limits = { five_hour = { used_percentage = 30, resets_at = 9 }, seven_day = { used_percentage = 60 } },
	}))
	write(config .. "/projects/-src-app/sid/subagents/agent-a1.jsonl", "")
	write(config .. "/projects/-src-app/sid/subagents/agent-a1.meta.json", rex.json.encode({ agentType = "Explore", description = "find it" }))
	write(config .. "/projects/-src-app/sid/subagents/agent-a2.jsonl", "")
	write(config .. "/projects/-src-app/sid/subagents/agent-a2.meta.json", rex.json.encode({ agentType = "Plan", finished = true }))
	if os.getenv("CLAUDE_CONFIG_DIR") and os.getenv("CLAUDE_CONFIG_DIR") ~= "" then
		print("CLAUDE_CONFIG_DIR is set; it's read before the test folder")
	end
	local cs = claude.session({ pid = 42 })
	equal(cs.id, "sid", "claude session")
	equal(cs.transcript, config .. "/projects/-src-app/sid.jsonl", "claude transcript")
	equal(cs.name, "Panel work", "claude session name")
	equal(cs.working, true, "claude working")
	equal(cs.started, 5, "claude start in seconds")
	equal(cs.model, "claude-test-1-0", "claude model")
	equal(cs.model_label, "Test 1.0", "claude model label")
	equal(cs.effort, "high", "claude effort")
	equal(cs.status.window, 200000, "claude context window")
	equal(cs.status.limits[1].label, "5h", "claude 5h limit")
	equal(cs.status.limits[2].used, 60, "claude 7d limit")
	equal(claude.session({ pid = 43 }), nil, "no session file")
	local path, cwd = claude.transcript(42)
	equal(path, cs.transcript, "transcript by pid")
	equal(cwd, "/src/app", "directory by pid")
	local list = claude.subagents(cs)
	table.sort(list, function(x, y)
		return x.id < y.id
	end)
	equal(#list, 2, "claude subagents")
	equal(list[1].type, "Explore", "subagent type")
	equal(list[1].running, true, "unfinished and recent")
	equal(list[2].finished, true, "finished subagent")
	equal(list[2].running, false, "finished isn't running")
	equal(#claude.subagents({}), 0, "no transcript, no subagents")
	local known = claude.subagents(cs, nil, { a1 = true })
	table.sort(known, function(x, y)
		return x.id < y.id
	end)
	equal(known[1].finished, true, "a subagent the caller knows finished")
	equal(known[1].type, nil, "its files not read again")
	equal(known[2].type, "Plan", "the others read")
end)
U.exec, U.home = real_exec, real_home
real_exec({ "rm", "-rf", tmp })
if not ok then
	error(err, 0)
end
return "agents: all tests passed"
