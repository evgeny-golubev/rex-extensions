-- Run: rex do ~/.config/rex/extensions/rex-resume/test.lua
-- Mocks the Rex API around real files in a temporary directory: it doesn't
-- touch live sessions or the real snapshot.
local real, real_getenv = rex, os.getenv
local dir = debug.getinfo(1, "S").source:match("^@?(.*/)")
local tmp = (assert(real.exec({ "/usr/bin/mktemp", "-d" })).stdout:gsub("%s+$", ""))
local snapshot = tmp .. "/sessions.json"
local settings = tmp .. "/settings.json"
local claude_file = tmp .. "/.claude/sessions/42.json"
assert(real.exec({ "/bin/mkdir", "-p", tmp .. "/.claude/sessions" }))

local function equal(actual, expected, what)
	if actual ~= expected then
		error(what .. ": " .. tostring(actual) .. " ~= " .. tostring(expected), 2)
	end
end

-- report.lua signs reports with the real shasum, before Rex is faked.
local report = dofile(dir .. "report.lua")
equal(report.base64("abc"), "YWJj", "base64")
equal(report.base64("/src/app"), "L3NyYy9hcHA=", "base64 with padding")
equal(
	report.body(7, { "agy", "--conversation", "abc" }, "/src/app", "dummy-token-replace-me-0123", 1795543200),
	"pid=7:time=1795543200:argv=YWd5,LS1jb252ZXJzYXRpb24=,YWJj:cwd=L3NyYy9hcHA="
		.. ":mac=1b313fe780ba2fcc6747ab4118517687f79a7be69cefc60e7114f28f5432ff9b",
	"signed report"
)

local function write(path, text)
	local f = assert(io.open(path, "w"))
	f:write(text)
	f:close()
end

local function read_json(path)
	local f = io.open(path)
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	return assert(real.json.decode(text))
end

local function shell(id, label)
	return {
		block_id = id,
		label = label,
		flavor = "com.superlogical.terminal.shell",
		creator_name = "com.superlogical.terminal",
	}
end

local clients, views, processes, created, timers, stopped, written, ps_calls, codex_thread, codex_asked
local records, reports, records_asked, handlers
REX_RESUME_REPORTER = {
	report = function(pid, argv, cwd)
		table.insert(reports, { pid = pid, command = table.concat(argv, " "), cwd = cwd })
		return true
	end,
}
REX_RESUME_CODEX = {
	session = function(pane)
		codex_asked = pane
		return codex_thread
	end,
}
local agy_conversation, pi_session, opencode_session
REX_RESUME_AGY = {
	session = function()
		return agy_conversation
	end,
}
REX_RESUME_PI = {
	session = function()
		return pi_session
	end,
}
REX_RESUME_OPENCODE = {
	session = function()
		return opencode_session
	end,
}

local function reset()
	clients, created, timers, stopped, written, ps_calls = {}, {}, {}, false, {}, {}
	codex_thread, codex_asked = nil, nil
	records, reports, records_asked, handlers = {}, {}, 0, {}
	views = {
		["session:1"] = {
			session_id = "session:1",
			label = "work",
			windows = { {
				label = "Window 89abcdef",
				layers = { {
					kind = "tiled",
					blocks = { shell("block:1", "shell"), shell("block:2", "agent") },
					layout = {
						split = {
							direction = "right",
							ratio = 0.5,
							before = { block_id = "block:1" },
							after = { block_id = "block:2" },
						},
					},
				} },
			} },
		},
	}
	processes = {
		["block:1"] = { foreground = { pid = 41, argv0 = "nvim", cwd = "/src/app" } },
		["block:2"] = { foreground = { pid = 42, argv0 = "claude", cwd = "/src/app/sub" } },
	}
	os.remove(snapshot)
	os.remove(snapshot .. ".prev")
	os.remove(claude_file)
	os.remove(settings)
end

local function run()
	local ok, err = pcall(assert(loadfile(dir .. "watcher.lua")))
	if not ok and err ~= "STOP" then
		error(err, 0)
	end
end

--- Runs the timers that are due, as rex.after would.
local function fire()
	local due = timers
	timers = {}
	for _, t in ipairs(due) do
		if not t.cancelled then
			t.fn()
		end
	end
end

local function agent_options()
	return read_json(snapshot).sessions[1].initial_windows[1].layout.split.after.block.options
end

local function shell_options()
	return read_json(snapshot).sessions[1].initial_windows[1].layout.split.before.block.options
end

rex = {
	args = { state = snapshot, settings = settings },
	call = function(method, params)
		if method == "client.list" then
			return { clients = clients }
		elseif method == "client.set_label" then
			return {}
		elseif method == "server.status" then
			return { instance_id = "server-2" }
		elseif method == "session.list" then
			local list = {}
			for id, v in pairs(views) do
				table.insert(list, { session_id = id, label = v.label })
			end
			return { sessions = list }
		elseif method == "session.attach" then
			return { view = views[params.session_id] }
		elseif method == "session.create" then
			table.insert(created, params)
			return { session_id = "session:new" }
		end
		error("unexpected call " .. method)
	end,
	block = {
		call = function(_, method, params)
			if method == "write" then
				table.insert(written, { block_id = params.block_id, data = params.data })
				return {}
			elseif method == "program_resume_records" then
				records_asked = records_asked + 1
				return { records = records[params.block_id] or {} }
			end
			return processes[params.block_id]
		end,
	},
	exec = function(argv)
		if argv[1] == "/bin/ps" then
			table.insert(ps_calls, argv[#argv])
			local f = processes["block:1"].foreground
			return { ok = true, stdout = f.pid == 41 and "nvim src/main.lua\n" or "" }
		end
		return { ok = true }
	end,
	json = real.json,
	on = function(event, fn)
		handlers[event] = fn
	end,
	after = function(delay, fn)
		local t = { delay = delay, fn = fn }
		function t:cancel()
			self.cancelled = true
		end
		table.insert(timers, t)
		return t
	end,
	sleep = function() end,
	log = function() end,
	stop = function()
		stopped = true
		error("STOP", 0)
	end,
}
os.getenv = function(name)
	if name == "HOME" then
		return tmp
	end
	return real_getenv(name)
end

local ok, err = pcall(function()
	-- Saves the layout, directories, and the Claude session to resume.
	reset()
	write(claude_file, '{"pid":42,"sessionId":"abc-123","cwd":"/src/app"}')
	run()
	local saved = read_json(snapshot)
	equal(saved.instance_id, "server-2", "instance")
	equal(saved.sessions[1].initial_windows[1].window_label, nil, "default window label")
	local split = saved.sessions[1].initial_windows[1].layout.split
	equal(split.before.block.options.cwd, "/src/app", "shell cwd")
	equal(split.before.block.options.initial_input, "nvim src/main.lua\n", "nvim with its arguments")
	equal(split.after.block.options.cwd, "/src/app", "claude cwd from its session file")
	equal(split.after.block.options.initial_input, "claude --resume abc-123\n", "claude resume")
	equal(#created, 0, "restored on the same server")
	equal(#timers, 0, "retry without need")

	-- allow_name brings a listed program back without reading its arguments.
	reset()
	write(settings, '{"mode":"allow_name"}')
	run()
	equal(shell_options().initial_input, "nvim\n", "nvim by name")
	equal(#ps_calls, 0, "arguments read in allow_name")

	-- A program missing from the list stays a shell, its arguments unread;
	-- Claude resumes even with an empty list.
	reset()
	write(settings, '{"mode":"allow_full","programs":[]}')
	write(claude_file, '{"pid":42,"sessionId":"abc-123","cwd":"/src/app"}')
	run()
	equal(shell_options().initial_input, nil, "unlisted program")
	equal(#ps_calls, 0, "arguments read for an unlisted program")
	equal(agent_options().initial_input, "claude --resume abc-123\n", "claude with an empty list")

	-- any_full brings back any program with its arguments, but not a shell.
	reset()
	write(settings, '{"mode":"any_full","programs":[]}')
	processes["block:1"].foreground.argv0 = "/opt/bin/mytool"
	run()
	equal(ps_calls[1], "41", "arguments of an unlisted program")
	equal(shell_options().initial_input, "nvim src/main.lua\n", "any program")
	reset()
	write(settings, '{"mode":"any_full"}')
	processes["block:1"].foreground.argv0 = "-zsh"
	run()
	equal(shell_options().initial_input, nil, "a shell")

	-- Codex comes back in its thread, in the thread's directory.
	reset()
	processes["block:1"].foreground.argv0 = "Codex"
	codex_thread = { id = "thread-7", cwd = "/src/app/api" }
	run()
	equal(codex_asked.pid, 41, "codex pane asked about")
	equal(codex_asked.block_id, "block:1", "codex pane's block")
	equal(shell_options().initial_input, "codex resume thread-7\n", "codex resume")
	equal(shell_options().cwd, "/src/app/api", "codex thread's directory")

	-- agy comes back in its conversation.
	reset()
	processes["block:1"].foreground.argv0 = "agy"
	agy_conversation = { id = "conv-9", cwd = "/src/app/web" }
	run()
	equal(shell_options().initial_input, "agy --conversation conv-9\n", "agy resume")
	equal(shell_options().cwd, "/src/app/web", "agy conversation's directory")
	agy_conversation = nil

	-- Pi comes back in its session file, OpenCode in its session.
	reset()
	processes["block:1"].foreground.argv0 = "pi"
	pi_session = { id = "p1", transcript = "/home/me/.pi/agent/sessions/--x--/it's.jsonl", cwd = "/src/app/pi" }
	run()
	equal(shell_options().initial_input, "pi --session '/home/me/.pi/agent/sessions/--x--/it'\\''s.jsonl'\n", "pi resume, quoted")
	equal(shell_options().cwd, "/src/app/pi", "pi session's directory")
	pi_session = nil
	reset()
	processes["block:1"].foreground.argv0 = "opencode"
	opencode_session = { id = "ses_42", cwd = "/src/app/oc" }
	run()
	equal(shell_options().initial_input, "opencode --session ses_42\n", "opencode resume")
	opencode_session = nil

	-- Codex doesn't tell Rex how to resume it, so this reports for it, until
	-- Rex has the record; the snapshot then says Rex restarts it itself.
	reset()
	processes["block:1"].foreground.argv0 = "codex"
	codex_thread = { id = "thread-7", cwd = "/src/app/api" }
	run()
	equal(#reports, 1, "report for codex")
	equal(reports[1].pid, 41, "reported pid")
	equal(reports[1].command, "codex resume thread-7", "reported command")
	equal(reports[1].cwd, "/src/app/api", "reported directory")
	equal(read_json(snapshot).sessions[1].initial_windows[1].layout.split.before.block.native, nil, "native before Rex has it")
	equal(#timers, 1, "check that Rex took the report")
	fire()
	equal(#reports, 2, "report again while Rex has none")
	records["block:1"] = { {
		owner = { pid = 41 }, chosen = true, trusted = true, rule = "codex", command = { "codex", "resume", "thread-7" },
	} }
	fire()
	equal(#reports, 2, "report once Rex has it")
	equal(read_json(snapshot).sessions[1].initial_windows[1].layout.split.before.block.native, true, "native")
	equal(shell_options().initial_input, "codex resume thread-7\n", "typed command kept as the fallback")

	-- A new thread in the same Codex is reported again.
	codex_thread = { id = "thread-8" }
	handlers["terminal.process_changed"]()
	fire()
	equal(#reports, 3, "report for the new thread")
	equal(reports[3].command, "codex resume thread-8", "new thread reported")

	-- The reports stop for a pane where Rex never takes them.
	reset()
	processes["block:1"].foreground.argv0 = "codex"
	codex_thread = { id = "thread-7" }
	run()
	for _ = 1, 10 do
		fire()
	end
	equal(#reports, 6, "reports for a pane Rex ignores")
	equal(#timers, 0, "checks after the last report")

	-- A program's own record is left alone.
	reset()
	processes["block:1"].foreground.argv0 = "codex"
	codex_thread = { id = "thread-7" }
	records["block:1"] = { { owner = { pid = 41 }, chosen = true, trusted = true, command = { "codex", "resume", "other" } } }
	run()
	equal(#reports, 0, "report over the program's own record")

	-- "native": "off" sends nothing and asks Rex nothing.
	reset()
	write(settings, '{"native":"off"}')
	processes["block:1"].foreground.argv0 = "codex"
	codex_thread = { id = "thread-7" }
	write(claude_file, '{"pid":42,"sessionId":"abc-123","cwd":"/src/app"}')
	run()
	equal(#reports, 0, "reports with native off")
	equal(records_asked, 0, "records read with native off")

	-- A Claude that reports itself is marked, and never reported for.
	reset()
	write(claude_file, '{"pid":42,"sessionId":"abc-123","cwd":"/src/app"}')
	records["block:2"] = { { owner = { pid = 42 }, chosen = true, trusted = true, command = { "claude", "--resume", "abc-123" } } }
	run()
	equal(read_json(snapshot).sessions[1].initial_windows[1].layout.split.after.block.native, true, "claude native")
	equal(#reports, 0, "report for claude")

	-- Before Codex has a thread, its command is kept and the save repeated.
	reset()
	processes["block:1"].foreground.argv0 = "codex"
	run()
	equal(shell_options().initial_input, "nvim src/main.lua\n", "codex's own command")
	equal(#timers, 1, "retries for codex's thread")
	codex_thread = { id = "thread-8" }
	fire()
	equal(shell_options().initial_input, "codex resume thread-8\n", "codex resume after retry")

	-- Without codex on the list, its thread isn't looked up.
	reset()
	write(settings, '{"programs":["nvim"]}')
	processes["block:1"].foreground.argv0 = "codex"
	codex_thread = { id = "thread-9" }
	run()
	equal(codex_asked, nil, "codex thread looked up")
	equal(shell_options().initial_input, nil, "codex not on the list")

	-- A claude that hasn't written its session file yet is saved again later.
	reset()
	run()
	equal(agent_options().initial_input, nil, "resume before the file exists")
	equal(agent_options().cwd, "/src/app/sub", "cwd before the file exists")
	equal(#timers, 1, "retries scheduled")
	equal(timers[1].delay, 5, "retry delay")
	write(claude_file, '{"pid":42,"sessionId":"abc-123","cwd":"/src/app"}')
	fire()
	equal(agent_options().initial_input, "claude --resume abc-123\n", "resume after retry")
	equal(#timers, 0, "retries after success")

	-- Claude started as `Claude` is still waited for, not saved as a program.
	reset()
	processes["block:2"].foreground.argv0 = "Claude"
	run()
	equal(#timers, 1, "retries for Claude")
	equal(agent_options().initial_input, nil, "Claude saved as a program")

	-- The retries stop for a claude that never writes one.
	reset()
	run()
	for _ = 1, 10 do
		fire()
	end
	equal(#timers, 0, "retries for a claude without a file")

	-- Restores the sessions missing from another server's snapshot, once.
	reset()
	local gone = {
		label = "gone",
		initial_windows = { {
			layout = {
				block = {
					flavor = "com.superlogical.terminal.shell",
					native = true,
					options = { cwd = "/x", initial_input = "claude --resume abc-123\n" },
				},
			},
		} },
	}
	write(snapshot, assert(real.json.encode({ instance_id = "server-1", sessions = { { label = "work" }, gone } })))
	run()
	equal(#created, 1, "sessions restored")
	equal(created[1].label, "gone", "restored session")
	equal(created[1].initial_windows[1].layout.block.options.initial_input, "claude --resume abc-123\n", "restored input")
	equal(created[1].initial_windows[1].layout.block.native, nil, "native mark sent to session.create")
	equal(read_json(snapshot .. ".prev").instance_id, "server-1", "previous snapshot")
	equal(read_json(snapshot).instance_id, "server-2", "new snapshot")

	-- In a session Rex brought back itself, Claude resumes in the pane that
	-- ran it: matched by directory, once its shell is up.
	local function saved_work(cwd)
		return {
			label = "work",
			initial_windows = { {
				layout = {
					split = {
						direction = "right",
						ratio = 0.5,
						before = { block = { label = "shell", options = { cwd = "/src/app" } } },
						after = { block = { label = "agent", options = { cwd = cwd, initial_input = "claude --resume abc-123\n" } } },
					},
				},
			} },
		}
	end
	reset()
	processes["block:1"] = { foreground = { pid = 51, argv0 = "-zsh", cwd = "/src/app" } }
	processes["block:2"] = { foreground = { pid = 52, argv0 = "-zsh", cwd = "/src/app/sub" } }
	write(snapshot, assert(real.json.encode({ instance_id = "server-1", sessions = { saved_work("/src/app/sub") } })))
	run()
	equal(#created, 0, "no session created for an open one")
	equal(#written, 1, "claude resumed")
	equal(written[1].block_id, "block:2", "pane with the same directory")
	equal(written[1].data, "claude --resume abc-123\n", "resume command")

	-- In another directory, it changes to Claude's first.
	reset()
	processes["block:1"] = { foreground = { pid = 51, argv0 = "zsh", cwd = "/src/app" } }
	processes["block:2"] = { foreground = { pid = 52, argv0 = "zsh", cwd = "/home" } }
	write(snapshot, assert(real.json.encode({ instance_id = "server-1", sessions = { saved_work("/it's/here") } })))
	run()
	equal(written[1].block_id, "block:2", "pane in the same place")
	equal(written[1].data, "cd '/it'\\''s/here' && claude --resume abc-123\n", "cd before resuming")

	-- Where Rex was to restart Claude but the pane stayed a shell, it is
	-- still typed back, after giving Rex its time.
	reset()
	processes["block:1"] = { foreground = { pid = 51, argv0 = "zsh", cwd = "/src/app" } }
	processes["block:2"] = { foreground = { pid = 52, argv0 = "zsh", cwd = "/src/app/sub" } }
	local native_work = saved_work("/src/app/sub")
	native_work.initial_windows[1].layout.split.after.block.native = true
	native_work.initial_windows[1].layout.split.before.block.native = true
	native_work.initial_windows[1].layout.split.before.block.options.initial_input = "claude --resume def-456\n"
	local slept = 0
	rex.sleep = function() slept = slept + 1 end
	write(snapshot, assert(real.json.encode({ instance_id = "server-1", sessions = { native_work } })))
	run()
	rex.sleep = function() end
	equal(#written, 2, "typed after Rex's turn")
	equal(written[2].data, "claude --resume abc-123\n", "second pane typed")
	equal(slept >= 20 and slept < 30, true, "one shared wait for Rex, slept " .. slept)

	-- A pane already running Claude, or another program, is left alone.
	reset()
	processes["block:1"] = { foreground = { pid = 51, argv0 = "zsh", cwd = "/src/app" } }
	write(snapshot, assert(real.json.encode({ instance_id = "server-1", sessions = { saved_work("/src/app/sub") } })))
	run()
	equal(#written, 0, "pane running claude")

	-- A changes pane isn't saved; the pane beside it takes its place.
	reset()
	local layer = views["session:1"].windows[1].layers[1]
	table.insert(layer.blocks, shell("block:3", "Sidecar: app"))
	layer.layout.split.after = {
		split = { direction = "right", ratio = 0.65, before = { block_id = "block:2" }, after = { block_id = "block:3" } },
	}
	run()
	local kept = read_json(snapshot).sessions[1].initial_windows[1].layout.split.after
	equal(kept.split, nil, "split around the sidecar pane")
	equal(kept.block.label, "agent", "pane beside the changes pane")

	-- Neither is a crab pane along the bottom of the tab.
	reset()
	layer = views["session:1"].windows[1].layers[1]
	table.insert(layer.blocks, shell("block:3", "Crabs"))
	layer.layout = { split = { direction = "down", ratio = 0.9, before = layer.layout, after = { block_id = "block:3" } } }
	run()
	kept = read_json(snapshot).sessions[1].initial_windows[1].layout.split
	equal(kept.direction, "right", "split above the crab pane")
	equal(kept.after.block.label, "agent", "panes above the crab pane")

	-- A second copy quits and leaves the first one's snapshot alone.
	reset()
	clients = { { info = { label = "rex-resume" } } }
	run()
	equal(stopped, true, "second copy stopped")
	equal(read_json(snapshot), nil, "second copy's snapshot")
end)
rex, os.getenv = real, real_getenv
REX_RESUME_CODEX, REX_RESUME_AGY, REX_RESUME_PI, REX_RESUME_OPENCODE, REX_RESUME_REPORTER = nil, nil, nil, nil, nil
real.exec({ "/bin/rm", "-rf", tmp })
if not ok then
	error(err, 0)
end
return "rex-resume: all tests passed"
