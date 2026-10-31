-- Remembers every session's tabs, splits and working directories, and brings
-- them back once after the Rex server restarts (reboot, update, crash).
-- init.lua starts it with every config load (`rex do --all watcher.lua`); it
-- then saves a snapshot a second after each layout, label, directory or
-- program change. `state=/tmp/x.json` points it at another snapshot file.
--
-- ponytail: of the programs that ran in the panes, only Claude Code comes back
-- (`claude --resume`, without its original flags); ssh, nvim and the rest
-- don't. Add a resume command per program if that is ever missed.

local terminal = "com.superlogical.terminal"
local home = os.getenv("HOME")
local path = rex.args.state or (home .. "/.config/rex/state/sessions.json")

--- Marks this script's server connection, so a second copy started by
--- `rex config reload` sees the first one and quits.
local client_label = "session-keeper"

--- Claude Code writes its process file a few seconds after it starts, so a
--- save that finds claude without one is repeated, up to this many times.
local claude_retries = 6
local claude_waits = {}
local claude_starting = false

local function check(value, err)
	if err ~= nil then
		error(err, 0)
	end
	return value
end

local function read_snapshot()
	local f = io.open(path)
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	return rex.json.decode(text)
end

--- The local directory of a terminal's foreground process, or of the shell
--- under it (a root-owned `sudo` has none). Unlike the OSC 7 `pwd`, this is
--- known as soon as the shell starts and stays local while ssh is running.
local function cwd(r)
	if r.foreground and r.foreground.cwd then
		return r.foreground.cwd
	end
	for _, p in ipairs(r.ancestors or {}) do
		if p.cwd then
			return p.cwd
		end
	end
end

--- The Claude Code session that process pid runs, from the file Claude Code
--- keeps for each of its running processes.
local function claude_session(pid)
	local f = io.open(home .. "/.claude/sessions/" .. pid .. ".json")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	local s = rex.json.decode(text)
	if s and s.pid == pid and s.sessionId and s.cwd then
		return s
	end
end

--- A terminal's `session.create` options: its directory, and the command that
--- brings back the Claude Code session in its foreground, if any. The command
--- is typed into a shell, so quitting Claude leaves the shell, as before.
local function terminal_options(session_id, block_id)
	local r = rex.block.call(terminal, "process", { session_id = session_id, block_id = block_id })
	if not r then
		return {}
	end
	local fg = r.foreground
	local claude = fg and claude_session(fg.pid)
	if claude then
		return { cwd = claude.cwd, initial_input = "claude --resume " .. claude.sessionId .. "\n" }
	end
	if fg and fg.argv0 and fg.argv0:match("claude$") then
		local waits = claude_waits[fg.pid] or 0
		if waits < claude_retries then
			claude_waits[fg.pid] = waits + 1
			claude_starting = true
		end
	end
	return { cwd = cwd(r) }
end

--- Turns a `session.view` layout node into a `session.create` layout node, or
--- nil when nothing in it is kept. Changes panes are left out: the
--- changes-pane extension opens them again beside the resumed Claude.
local function capture(node, view, blocks)
	if node.split then
		local s = node.split
		local before, after = capture(s.before, view, blocks), capture(s.after, view, blocks)
		if not (before and after) then
			return before or after
		end
		return {
			split = {
				direction = s.direction,
				ratio = s.ratio,
				before = before,
				after = after,
			},
		}
	end
	local b = blocks[node.block_id]
	if b.label and (b.label:sub(1, 9) == "Changes: " or b.label == "Crabs") then
		return nil
	end
	local block = { flavor = b.flavor, label = b.label, options = {} }
	if b.creator_name == terminal then
		block.options = terminal_options(view.session_id, node.block_id)
	end
	return { block = block }
end

--- One session as `session.create` arguments, or nil when it has no tiled tab.
local function capture_session(s)
	local view = check(rex.call("session.attach", { session_id = s.session_id })).view
	local windows = {}
	for _, w in ipairs(view.windows) do
		for _, l in ipairs(w.layers) do
			if l.kind == "tiled" and l.layout then
				local blocks = {}
				for _, b in ipairs(l.blocks) do
					blocks[b.block_id] = b
				end
				local layout = capture(l.layout, view, blocks)
				if layout then
					local window = { layout = layout }
					if not w.label:match("^Window %x+$") then
						window.window_label = w.label
					end
					table.insert(windows, window)
				end
			end
		end
	end
	if #windows == 0 then
		return nil
	end
	return { label = view.label, initial_windows = windows }
end

local schedule

local function save()
	claude_starting = false
	local out = { instance_id = check(rex.call("server.status")).instance_id, sessions = {} }
	for _, s in ipairs(check(rex.call("session.list")).sessions) do
		table.insert(out.sessions, capture_session(s))
	end
	local f = assert(io.open(path .. ".tmp", "w"))
	f:write(check(rex.json.encode(out, { indent = true })))
	f:close()
	check(os.rename(path .. ".tmp", path))
	if claude_starting then
		schedule(5)
	end
end

-- Changes come in bursts (one split fires several events), so save once
-- a second after the last one.
local pending
schedule = function(delay)
	if pending then
		pending:cancel()
	end
	pending = rex.after(delay, save)
end

for _, c in ipairs(check(rex.call("client.list")).clients) do
	if c.info and c.info.label == client_label then
		rex.stop(0)
	end
end
check(rex.call("client.set_label", { label = client_label }))
check(rex.exec({ "mkdir", "-p", (path:match("^(.*)/")) }))

local status = check(rex.call("server.status"))
local sessions = check(rex.call("session.list")).sessions
local snapshot = read_snapshot()

if snapshot and snapshot.instance_id ~= status.instance_id then
	local open = {}
	for _, s in ipairs(sessions) do
		open[s.label] = true
	end
	for _, s in ipairs(snapshot.sessions) do
		if not open[s.label] then
			local _, err = rex.call("session.create", s)
			if err ~= nil then
				rex.log("warn", "restoring " .. s.label .. ": " .. err)
			end
		end
	end
	-- A session that failed to restore would vanish with the next save.
	os.rename(path, path .. ".prev")
	-- New shells have no process, and so no cwd to capture, for a moment.
	rex.sleep(2)
end
save()

for _, event in ipairs({
	"session_created",
	"session_destroyed",
	"session_label_changed",
	"session_view_changed",
	"window_label_changed",
	"terminal.pwd_changed",
	"terminal.process_changed",
}) do
	rex.on(event, function()
		schedule(1)
	end)
end
