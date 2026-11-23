-- The Claude Code adapter: finds a pane's Claude, its session files, its
-- subagents and what its status line reported. See agents/init.lua for the
-- interface every adapter has.
return function(U)
	local M = {
		id = "claude",
		name = "Claude",
		theme = {
			accent = "#D97757", -- Anthropic Terracotta
			agent = "#E89A7F", -- Soft Clay
			clock = "#6A9BCC", -- Anthropic Slate Blue
			gradient = { "#C96442", "#D97757", "#E89A7F" },
		},
	}

	--- Where Claude Code keeps its files: CLAUDE_CONFIG_DIR, then ~/.claude.
	local function config_dirs()
		local dirs = {}
		local custom = os.getenv("CLAUDE_CONFIG_DIR")
		if custom and custom ~= "" then
			dirs[#dirs + 1] = custom
		end
		dirs[#dirs + 1] = U.home .. "/.claude"
		return dirs
	end

	function M.matches(p)
		return p ~= nil and p.argv0 ~= nil and U.basename(p.argv0):lower() == "claude"
	end

	--- Claude Code keeps a project's transcripts in a folder named after its
	--- directory, with every character but letters and digits made a dash.
	function M.project_dir(cwd)
		return (cwd:gsub("[^%w]", "-"))
	end

	local found = {}

	--- The session file Claude Code writes for each running Claude, the
	--- folder it's in, and the session's transcript. /cd changes the
	--- directory there, and moves the transcript with it.
	local function session_file(pid)
		for _, dir in ipairs(config_dirs()) do
			local s = U.read_json(dir .. "/sessions/" .. pid .. ".json")
			if s and s.sessionId then
				local path = s.cwd and (dir .. "/projects/" .. M.project_dir(s.cwd) .. "/" .. s.sessionId .. ".jsonl")
				local f = path and io.open(path, "rb")
				if f then
					f:close()
					return s, dir, path
				end
				if found[s.sessionId] == nil then
					local r = U.exec({ "/usr/bin/find", dir .. "/projects", "-maxdepth", "2", "-name", s.sessionId .. ".jsonl" })
					found[s.sessionId] = r and r.ok and r.stdout:match("[^\n]+") or false
				end
				return s, dir, found[s.sessionId] or nil
			end
		end
	end

	--- The transcript and current directory of the Claude with this process ID.
	function M.transcript(pid)
		local s, _, path = session_file(pid)
		if s then
			return path, s.cwd
		end
	end

	--- The context window and usage limits from the status line's saved input.
	function M.status(sl)
		local out = { limits = {} }
		local window = type(sl.context_window) == "table" and tonumber(sl.context_window.context_window_size)
		out.window = window
		local limits = type(sl.rate_limits) == "table" and sl.rate_limits or {}
		for _, w in ipairs({ { "5h", limits.five_hour }, { "7d", limits.seven_day } }) do
			local limit = w[2]
			if type(limit) == "table" and tonumber(limit.used_percentage) then
				out.limits[#out.limits + 1] = { label = w[1], used = tonumber(limit.used_percentage), resets_at = tonumber(limit.resets_at) }
			end
		end
		return out
	end

	function M.session(pane)
		local s, dir, path = session_file(pane.pid)
		if not s then
			return nil
		end
		local sl = U.read_json(dir .. "/state/statusline/" .. s.sessionId .. ".json") or {}
		local model = type(sl.model) == "table" and sl.model or {}
		return {
			id = s.sessionId,
			pid = pane.pid,
			transcript = path,
			cwd = s.cwd,
			name = sl.session_name or s.name,
			started = tonumber(s.startedAt) and s.startedAt / 1000 or nil,
			working = s.status == "busy",
			model = model.id or model.display_name,
			model_label = model.display_name,
			effort = type(sl.effort) == "table" and sl.effort.level or nil,
			status = M.status(sl),
		}
	end

	--- The session's subagents, from the folder beside its transcript. A
	--- subagent stopped by a crash or a resume never gets `finished`, so only
	--- one whose transcript moved in the last 10 minutes counts as running.
	--- `done` holds the IDs the caller knows finished, whose files aren't
	--- read again.
	function M.subagents(sess, _, done)
		if not sess.transcript then
			return {}
		end
		local folder = sess.transcript:gsub("%.jsonl$", "") .. "/subagents/"
		local r = U.exec({ "/bin/ls", folder })
		if not (r and r.ok) then
			return {}
		end
		done = done or {}
		local ids, open = {}, false
		for id in r.stdout:gmatch("agent%-([%w_%-]+)%.jsonl") do
			ids[#ids + 1] = id
			open = open or not done[id]
		end
		local recent = {}
		local f = open and U.exec({ "/usr/bin/find", folder, "-name", "*.jsonl", "-mmin", "-10" })
		for path in (f and f.ok and f.stdout or ""):gmatch("[^\n]+") do
			recent[U.basename(path)] = true
		end
		local out = {}
		for _, id in ipairs(ids) do
			local meta = done[id] and { finished = true } or U.read_json(folder .. "agent-" .. id .. ".meta.json") or {}
			local finished = meta.finished == true
			out[#out + 1] = {
				id = id,
				transcript = folder .. "agent-" .. id .. ".jsonl",
				type = meta.agentType,
				description = meta.description,
				finished = finished,
				running = not finished and recent["agent-" .. id .. ".jsonl"] == true,
			}
		end
		return out
	end

	return M
end
