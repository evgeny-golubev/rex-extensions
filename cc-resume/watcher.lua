-- Remembers every session's tabs, splits and working directories, and brings
-- them back once after the Rex server restarts (reboot, update, crash). Rex
-- now brings sessions back itself, with new IDs and without the programs
-- that ran in them, so for those this only resumes Claude Code in the panes
-- that ran it.
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
local client_label = "cc-resume"

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

local function is_helper(label)
	return label ~= nil and (label:sub(1, 9) == "Changes: " or label == "Crabs")
end

--- Turns a `session.view` layout node into a `session.create` layout node, or
--- nil when nothing in it is kept. Changes panes are left out: the
--- cc-pane extension opens them again beside the resumed Claude.
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
	if is_helper(b.label) then
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

-- Restoring ------------------------------------------------------------------

--- The sessions once their list has stayed the same for 3 seconds, as Rex's
--- own restore adds them a moment after the server starts; at most 20.
local function settled_sessions()
	local last, same = nil, 0
	for _ = 1, 20 do
		local list = check(rex.call("session.list")).sessions
		local ids = {}
		for _, s in ipairs(list) do
			ids[#ids + 1] = s.session_id
		end
		table.sort(ids)
		local key = table.concat(ids, ",")
		if key == last then
			same = same + 1
			if same >= 3 then
				return list
			end
		else
			last, same = key, 0
		end
		rex.sleep(1)
	end
	return check(rex.call("session.list")).sessions
end

--- A snapshot layout's blocks, in order.
local function saved_panes(node, out)
	out = out or {}
	if node.split then
		saved_panes(node.split.before, out)
		saved_panes(node.split.after, out)
	elseif node.block then
		out[#out + 1] = node.block
	end
	return out
end

--- An open layout's terminal block IDs, in order, without helper panes.
local function open_panes(node, blocks, out)
	out = out or {}
	if node.split then
		open_panes(node.split.before, blocks, out)
		open_panes(node.split.after, blocks, out)
	else
		local b = blocks[node.block_id]
		if b and b.creator_name == terminal and not is_helper(b.label) then
			out[#out + 1] = node.block_id
		end
	end
	return out
end

local shells = { zsh = true, bash = true, fish = true, sh = true, dash = true, ksh = true, tcsh = true }

local function program(r)
	local argv0 = r and r.foreground and r.foreground.argv0
	return argv0 and argv0:match("[^/]*$"):gsub("^%-", "")
end

local function quote(text)
	return "'" .. text:gsub("'", "'\\''") .. "'"
end

--- Types a saved `claude --resume` into an open pane once its shell is up:
--- a pane already running Claude, or another program, is left alone.
local function resume_in(session_id, block_id, saved)
	local r
	for _ = 1, 20 do
		r = rex.block.call(terminal, "process", { session_id = session_id, block_id = block_id })
		if r and r.foreground then
			break
		end
		rex.sleep(0.5)
	end
	if not shells[program(r) or ""] then
		return false
	end
	local input = saved.initial_input
	local here = r and cwd(r)
	if saved.cwd and here ~= saved.cwd then
		input = "cd " .. quote(saved.cwd) .. " && " .. input
	end
	local _, err = rex.block.call(terminal, "write", { session_id = session_id, block_id = block_id, data = input })
	if err ~= nil then
		rex.log("warn", "resuming Claude: " .. err)
		return false
	end
	return true
end

--- Resumes the Claude sessions of a saved session in the open one Rex brought
--- back. Each saved tab is matched by its label, or else its place; each
--- Claude pane in it by its directory, or else its place.
local function resume_claudes(open, saved)
	local view = check(rex.call("session.attach", { session_id = open.session_id })).view
	local windows = {}
	for _, w in ipairs(view.windows) do
		for _, l in ipairs(w.layers) do
			if l.kind == "tiled" and l.layout then
				local blocks = {}
				for _, b in ipairs(l.blocks) do
					blocks[b.block_id] = b
				end
				windows[#windows + 1] = { label = w.label, panes = open_panes(l.layout, blocks) }
			end
		end
	end
	local taken = {}
	for i, sw in ipairs(saved.initial_windows or {}) do
		local window
		for _, w in ipairs(windows) do
			if sw.window_label and w.label == sw.window_label and not taken[w] then
				window = w
			end
		end
		window = window or (not taken[windows[i]] and windows[i]) or nil
		if window then
			taken[window] = true
			local used, dirs = {}, {}
			local function dir_of(id)
				if dirs[id] == nil then
					local r = rex.block.call(terminal, "process", { session_id = open.session_id, block_id = id })
					dirs[id] = r and cwd(r) or false
				end
				return dirs[id]
			end
			for j, block in ipairs(saved_panes(sw.layout)) do
				local o = block.options or {}
				if o.initial_input then
					local target
					for _, id in ipairs(window.panes) do
						if not target and not used[id] and dir_of(id) == o.cwd then
							target = id
						end
					end
					local at = window.panes[j]
					target = target or (at and not used[at] and at) or nil
					if target then
						used[target] = true
						resume_in(open.session_id, target, o)
					end
				end
			end
		end
	end
end

for _, c in ipairs(check(rex.call("client.list")).clients) do
	if c.info and c.info.label == client_label then
		rex.stop(0)
	end
end
check(rex.call("client.set_label", { label = client_label }))
check(rex.exec({ "mkdir", "-p", (path:match("^(.*)/")) }))

local status = check(rex.call("server.status"))
local snapshot = read_snapshot()

if snapshot and snapshot.instance_id ~= status.instance_id then
	local open = {}
	for _, s in ipairs(settled_sessions()) do
		open[s.label] = s
	end
	for _, s in ipairs(snapshot.sessions) do
		if open[s.label] then
			local ok, err = pcall(resume_claudes, open[s.label], s)
			if not ok then
				rex.log("warn", "resuming in " .. s.label .. ": " .. tostring(err))
			end
		else
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
