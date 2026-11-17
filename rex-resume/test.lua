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

local clients, views, processes, created, timers, stopped, written, ps_calls

local function reset()
	clients, created, timers, stopped, written, ps_calls = {}, {}, {}, false, {}, {}
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
	on = function() end,
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
real.exec({ "/bin/rm", "-rf", tmp })
if not ok then
	error(err, 0)
end
return "rex-resume: all tests passed"
