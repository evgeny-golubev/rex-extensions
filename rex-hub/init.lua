-- Rex Hub: lets any coding agent (or the user) spawn another agent (Claude,
-- Codex, agy, Pi, OpenCode) in a minimized floating layer inside the same tab,
-- talk to interactive runs, read their output, and toggle/stop them.
--
-- Load from ~/.config/rex/init.lua with:
--   require("extensions.rex-hub")

local home = os.getenv("HOME") or ""
local base = home .. "/.config/rex/extensions/rex-hub/"
local rex_binary = home
	.. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
local terminal = "com.superlogical.terminal"

local core = dofile(base .. "core.lua")
local wrapper = base .. "run-wrapper.sh"

-- Run IDs and temp files use math.random.
math.randomseed(os.time())

-- rex.sleep is missing in init.lua (scripts only), so actions wait with /bin/sleep.
local function sleep(seconds)
	rex.exec({ "/bin/sleep", tostring(seconds) }, { timeout = seconds + 2 })
end

local function session_view(session_id)
	local r, err = rex.call("session.view", { session_id = session_id })
	if not r then
		return nil, err
	end
	return r.view or r
end

--- Finds the window holding `block_id`, or the active window of the session.
local function find_window(view, block_id)
	if block_id then
		for _, w in ipairs(view.windows or {}) do
			for _, l in ipairs(w.layers or {}) do
				for _, b in ipairs(l.blocks or {}) do
					if b.block_id == block_id then
						return w
					end
				end
			end
		end
	end
	for _, w in ipairs(view.windows or {}) do
		if w.window_id == view.active_window_id then
			return w
		end
	end
	return (view.windows or {})[1]
end

--- Finds a floating layer by ID in `view`, returning the layer table or nil.
local function find_layer(view, layer_id)
	for _, w in ipairs(view.windows or {}) do
		for _, l in ipairs(w.layers or {}) do
			if l.layer_id == layer_id then
				return l
			end
		end
	end
end

local function block_cwd(session_id, block_id)
	if not session_id or not block_id then
		return nil
	end
	local ok, p = pcall(rex.block.call, terminal, "process", { session_id = session_id, block_id = block_id })
	if not ok or not p then
		return nil
	end
	if p.foreground and p.foreground.cwd then
		return p.foreground.cwd
	end
	for _, a in ipairs(p.ancestors or {}) do
		if a.cwd then
			return a.cwd
		end
	end
end

--- Captures the visible screen + recent scrollback of a child terminal block.
local function capture_block(session_id, block_id, lines)
	if not session_id or not block_id then
		return nil
	end
	local r = rex.exec({ rex_binary, "--autostart=false", "capture", "-s", session_id, "-b", block_id }, { timeout = 5 })
	if not r or not r.ok or not r.stdout then
		return nil
	end
	local text = core.strip_ansi(r.stdout):gsub("%s+$", "")
	if lines and lines > 0 then
		local buf = {}
		for line in (text .. "\n"):gmatch("([^\n]*)\n") do
			buf[#buf + 1] = line
		end
		if #buf > lines then
			local slice = {}
			for i = #buf - lines + 1, #buf do
				slice[#slice + 1] = buf[i]
			end
			text = table.concat(slice, "\n")
		end
	end
	return text
end

--- Sends input text + Enter to a running child block.
local function send_to_block(session_id, block_id, message)
	if not session_id or not block_id then
		return nil, "the agent's pane isn't ready yet"
	end
	local r = rex.exec({
		rex_binary,
		"--autostart=false",
		"send",
		"-s",
		session_id,
		"-b",
		block_id,
		"--",
		tostring(message or "") .. "\r",
	}, { timeout = 5 })
	if not r or not r.ok then
		return nil, (r and r.stderr) or "failed to send input to block"
	end
	return true
end

--- A finished oneshot run's answer, or its stderr when it gave none and failed.
local function run_output(run)
	local out = core.read_output_file(run.result_file, 32000)
	if (not out or out == "") and run.status ~= "done" and run.result_file then
		out = core.read_output_file(core.error_path(core.state_dir(), run.id), 8000)
	end
	return out
end

--- Refreshes a run's live state against Rex (checks if layer is still open/minimized).
local function refresh_run(run)
	local dir = core.state_dir()
	local fresh = core.load_run(dir, run.id) or run
	if not fresh.layer_id or (fresh.layer_state == "closed" and fresh.status ~= "running") then
		return fresh
	end
	local view, err = session_view(fresh.session_id)
	-- Only a session that is gone for good closes its runs; other errors change nothing.
	if not view and not tostring(err):find("not_found", 1, true) then
		return fresh
	end
	local layer = view and find_layer(view, fresh.layer_id)
	if layer then
		fresh.layer_state = layer.state == "minimized" and "minimized" or "normal"
	else
		-- Re-read: the wrapper may have recorded its exit while session.view ran.
		fresh = core.load_run(dir, run.id) or fresh
		fresh.layer_state = "closed"
		-- The wrapper records its own exit before the float closes, so a run
		-- still marked running here was killed with its float.
		if fresh.status == "running" then
			fresh.status = "stopped"
			fresh.finished = fresh.finished or os.time()
			core.save_run(dir, fresh)
		end
	end
	return fresh
end

-- 1. hub_run: spawn another agent in a minimized floating layer in the same tab.
rex.action({
	name = "hub_run",
	title = "Hub: Run Agent",
	category = "Hub",
	args = {
		agent = "string",
		task = "string?",
		mode = "string?",
		cwd = "string?",
		model = "string?",
		wait = "boolean?",
		timeout = "number?",
		parent = "string?",
		session = "string?",
	},
	run = function(ctx, args)
		-- Rex ends an action called through `rex do` after 30 s, counted from here.
		local began = os.time()
		args = args or {}
		local session_id = args.session or ctx.session_id or os.getenv("REX_SESSION")
		local parent_block_id = args.parent or ctx.block_id or os.getenv("REX_BLOCK")
		if not session_id then
			error("hub_run: no Rex session_id available", 0)
		end

		local mode = args.mode or "oneshot"
		local agent = tostring(args.agent or ""):lower()
		local task = tostring(args.task or "")
		local argv, err = core.build_command(agent, mode, task, args.model)
		if not argv then
			error("hub_run: " .. err, 0)
		end

		local view, verr = session_view(session_id)
		if not view then
			error("hub_run: " .. tostring(verr), 0)
		end
		local window = find_window(view, parent_block_id)
		if not window then
			error("hub_run: no window found in session", 0)
		end

		local cwd = args.cwd or block_cwd(session_id, parent_block_id) or home
		local dir = core.state_dir()
		core.prune(dir, 7)
		local id = core.new_id(agent, dir)
		-- Only oneshot runs tee their output to a file.
		local result_file = mode == "oneshot" and core.result_path(dir, id) or nil

		-- The wrapper ends a oneshot run after `timeout` seconds; an interactive one has none.
		local limit = mode == "oneshot" and math.max(1, math.floor(args.timeout or 600)) or 0
		local cmd = { wrapper, dir, id, mode, cwd, tostring(limit), "--" }
		for _, a in ipairs(argv) do
			cmd[#cmd + 1] = a
		end

		-- Saved before the agent starts, so the wrapper can record even an instant failure.
		local run = {
			id = id,
			agent = agent,
			mode = mode,
			task = task,
			model = args.model,
			cwd = cwd,
			session_id = session_id,
			window_id = window.window_id,
			parent_block_id = parent_block_id,
			result_file = result_file,
			started = os.time(),
			status = "running",
			layer_state = "minimized",
		}
		core.save_run(dir, run)

		-- No `shell = "none"`: the command needs the login shell's PATH (e.g. ~/.local/bin/agy).
		local created, cerr = rex.call("session.new_layer", {
			session_id = session_id,
			window_id = window.window_id,
			bounds = { 0.1, 0.08, 0.8, 0.78 },
			focus = false,
			layout = {
				block = {
					flavor = terminal .. ".shell",
					label = core.hub_label(agent, task),
					options = {
						command = cmd,
						cwd = cwd,
					},
				},
			},
		})
		if not created then
			run.status = "failed"
			run.layer_state = "closed"
			run.finished = os.time()
			core.save_run(dir, run)
			error("hub_run: could not open floating layer: " .. tostring(cerr), 0)
		end

		local layer_id = created.layer_id
		local child_block_id = created.block_ids and created.block_ids[1]

		-- Minimize immediately so the delegated agent runs out of the way in the same tab.
		rex.call("session.set_layer_state", {
			session_id = session_id,
			layer_id = layer_id,
			state = "minimized",
		})

		run = core.load_run(dir, id) or run
		run.layer_id = layer_id
		run.child_block_id = child_block_id
		if run.status == "running" then
			run.layer_state = "minimized"
		else
			-- Stopped by hub_stop while the float was opening, or already ended.
			rex.call("session.close_layer", { session_id = session_id, layer_id = layer_id })
			run.layer_state = "closed"
		end
		core.save_run(dir, run)

		local should_wait = args.wait
		if should_wait == nil then
			should_wait = (mode == "oneshot")
		end

		if not should_wait then
			return {
				id = id,
				agent = agent,
				mode = mode,
				status = run.status,
				layer_id = layer_id,
				block_id = child_block_id,
			}
		end

		-- A longer run is handed back still running, for the caller to poll.
		local deadline = began + 25
		run = refresh_run(run)
		while run.status == "running" and os.time() < deadline do
			sleep(1)
			run = refresh_run(run)
		end
		if run.status == "running" then
			return {
				id = id,
				agent = agent,
				mode = mode,
				status = "running",
				layer_id = layer_id,
				block_id = child_block_id,
				note = "Still running after 25 s. Poll `rex do hub_status id=" .. id .. "` until it ends, then `rex do hub_read id=" .. id .. "`.",
			}
		end

		local output = run_output(run)
			or (run.layer_state ~= "closed" and capture_block(session_id, child_block_id, 120))
			or ""

		return {
			id = run.id,
			agent = run.agent,
			mode = run.mode,
			status = run.status,
			exit_code = run.exit_code,
			output = output,
		}
	end,
})

-- 2. hub_send: send a follow-up message to an interactive Hub agent.
rex.action({
	name = "hub_send",
	title = "Hub: Send Message to Agent",
	category = "Hub",
	args = {
		id = "string",
		message = "string",
	},
	run = function(_, args)
		args = args or {}
		local run = core.load_run(core.state_dir(), args.id)
		if not run then
			error("hub_send: unknown run id: " .. tostring(args.id), 0)
		end
		run = refresh_run(run)
		if run.layer_state == "closed" then
			error("hub_send: agent layer is already closed", 0)
		end
		local ok, err = send_to_block(run.session_id, run.child_block_id, args.message)
		if not ok then
			error("hub_send: " .. tostring(err), 0)
		end
		return { id = run.id, sent = true, status = run.status }
	end,
})

-- 3. hub_read: read output/screen from a Hub agent (oneshot result or interactive capture).
rex.action({
	name = "hub_read",
	title = "Hub: Read Agent Output",
	category = "Hub",
	args = {
		id = "string",
		lines = "number?",
	},
	run = function(_, args)
		args = args or {}
		local run = core.load_run(core.state_dir(), args.id)
		if not run then
			error("hub_read: unknown run id: " .. tostring(args.id), 0)
		end
		run = refresh_run(run)
		local output
		if run.mode == "oneshot" and run.status ~= "running" then
			output = run_output(run)
		end
		if not output and run.layer_state ~= "closed" then
			output = capture_block(run.session_id, run.child_block_id, args.lines or 120)
		end
		if not output then
			output = run_output(run) or ""
		end
		return {
			id = run.id,
			agent = run.agent,
			mode = run.mode,
			status = run.status,
			layer_state = run.layer_state,
			exit_code = run.exit_code,
			output = output,
		}
	end,
})

-- 4. hub_status: list Hub runs or inspect one run.
rex.action({
	name = "hub_status",
	title = "Hub: Agent Status",
	category = "Hub",
	args = {
		id = "string?",
		parent = "string?",
	},
	run = function(ctx, args)
		args = args or {}
		local dir = core.state_dir()
		if args.id then
			local run = core.load_run(dir, args.id)
			if not run then
				error("hub_status: unknown run id: " .. tostring(args.id), 0)
			end
			return refresh_run(run)
		end
		local filter = {}
		if args.parent then
			filter.parent_block_id = args.parent
		elseif ctx.session_id then
			filter.session_id = ctx.session_id
		end
		local runs = core.list_runs(dir, filter)
		local out = {}
		for _, r in ipairs(runs) do
			out[#out + 1] = refresh_run(r)
		end
		return { runs = out }
	end,
})

-- 5. hub_toggle: expand & focus a minimized Hub float, or minimize it back.
-- open=true always expands and focuses it.
rex.action({
	name = "hub_toggle",
	title = "Hub: Toggle Delegated Agent",
	category = "Hub",
	args = {
		id = "string?",
		open = "boolean?",
	},
	run = function(ctx, args)
		args = args or {}
		local dir = core.state_dir()
		local run
		if args.id then
			run = core.load_run(dir, args.id)
		else
			-- Pick the newest active (non-closed) run in the current session.
			local runs = core.list_runs(dir, ctx.session_id and { session_id = ctx.session_id } or nil)
			for i = #runs, 1, -1 do
				local r = refresh_run(runs[i])
				if r.layer_state ~= "closed" then
					run = r
					break
				end
			end
		end
		if not run then
			error("hub_toggle: no active delegated agent found", 0)
		end
		run = refresh_run(run)
		if run.layer_state == "closed" then
			error("hub_toggle: agent layer is closed", 0)
		end
		local target = (args.open or run.layer_state == "minimized") and "normal" or "minimized"
		local _, err = rex.call("session.set_layer_state", {
			session_id = run.session_id,
			layer_id = run.layer_id,
			state = target,
			focus = target == "normal" or nil,
		})
		if err then
			error("hub_toggle: " .. tostring(err), 0)
		end
		run = core.load_run(dir, run.id) or run
		-- The wrapper may have exited (and closed the float) meanwhile.
		if run.layer_state ~= "closed" then
			run.layer_state = target
			core.save_run(dir, run)
		end
		return { id = run.id, layer_state = run.layer_state }
	end,
})

-- 6. hub_stop: close an interactive (or stuck oneshot) Hub agent and its floating layer.
rex.action({
	name = "hub_stop",
	title = "Hub: Stop Delegated Agent",
	category = "Hub",
	args = {
		id = "string",
	},
	run = function(_, args)
		args = args or {}
		local dir = core.state_dir()
		local run = core.load_run(dir, args.id)
		if not run then
			error("hub_stop: unknown run id: " .. tostring(args.id), 0)
		end
		-- Record the stop before closing: the wrapper's hang-up trap keeps it.
		if run.status == "running" then
			run.status = "stopped"
			run.finished = os.time()
			core.save_run(dir, run)
		end
		if run.layer_id and run.session_id and run.layer_state ~= "closed" then
			local closed, cerr = rex.call("session.close_layer", {
				session_id = run.session_id,
				layer_id = run.layer_id,
			})
			if not closed and refresh_run(run).layer_state ~= "closed" then
				error("hub_stop: could not close the agent's float: " .. tostring(cerr), 0)
			end
		end
		run = core.load_run(dir, args.id) or run
		run.layer_state = "closed"
		core.save_run(dir, run)
		return { id = run.id, status = run.status, layer_state = "closed" }
	end,
})
