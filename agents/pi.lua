-- The Pi adapter (pi-coding-agent). Pi keeps each session as a JSONL file in
-- ~/.pi/agent/sessions/--<folder, with / as ->--/<time>_<id>.jsonl. Pi
-- names its process "pi", hiding its command line, so a pane's session is:
--   1. the one agents/pi-rex-status.ts, when installed as a Pi extension,
--      records for the process in ~/.pi/agent/state/rex/<pid>.json, with the
--      model's context window and whether Pi is working;
--   2. else the newest file in the folder's directory that changed since this
--      pi started. A pi that hasn't saved a message yet has none.
-- Subagents (the pi-subagents package) are Pi sessions of their own, under
-- <session>/<run>/run-<n>/. See agents/init.lua for the interface.
return function(U)
	local M = { id = "pi", name = "Pi" }

	M.cache_ttl = 5

	function M.home()
		local custom = os.getenv("PI_CODING_AGENT_DIR")
		return (custom and custom ~= "") and custom or U.home .. "/.pi/agent"
	end

	function M.matches(p)
		return p ~= nil and p.argv0 ~= nil and U.basename(p.argv0):lower() == "pi"
	end

	--- The folder Pi keeps a directory's sessions in.
	function M.session_dir(cwd)
		return M.home() .. "/sessions/--" .. tostring(cwd):gsub("^[/\\]", ""):gsub("[/\\:]", "-") .. "--"
	end

	--- The files `stat -f '%m %N'` lists, as { path, mtime }, newest first.
	function M.by_mtime(stat)
		local out = {}
		for mtime, path in tostring(stat or ""):gmatch("(%d+) ([^\n]+%.jsonl)") do
			out[#out + 1] = { path = path, mtime = tonumber(mtime) }
		end
		table.sort(out, function(a, b)
			return a.mtime > b.mtime
		end)
		return out
	end

	local function newest(dir, depth)
		local r = U.exec({ "/usr/bin/find", dir, "-maxdepth", tostring(depth), "-name", "*.jsonl", "-exec", "/usr/bin/stat", "-f", "%m %N", "{}", "+" })
		return M.by_mtime(r and r.ok and r.stdout or "")
	end

	--- The model and thinking level of the latest records of a transcript.
	function M.model(path)
		local f = io.open(path, "rb")
		if not f then
			return nil
		end
		local size = f:seek("end")
		f:seek("set", math.max(0, size - 262144))
		local tail = f:read("*a") or ""
		f:close()
		local model, effort
		for m in tail:gmatch('"modelId":"([^"]+)"') do
			model = m
		end
		for m in tail:gmatch('"role":"assistant".-"model":"([^"]+)"') do
			model = m
		end
		for e in tail:gmatch('"thinkingLevel":"([^"]+)"') do
			effort = e
		end
		return model, effort
	end

	local cache = {}

	function M.session(pane)
		local key = tostring(pane.pid) .. "\0" .. tostring(pane.cwd)
		local now = os.time()
		local hit = cache[key]
		if hit and now - hit.at < M.cache_ttl then
			return hit.sess
		end
		local started = U.started(pane.pid, now)
		local status = U.read_json(M.home() .. "/state/rex/" .. tostring(pane.pid) .. ".json") or {}
		local path = type(status.sessionFile) == "string" and status.sessionFile or nil
		if not path and pane.cwd then
			local first = newest(M.session_dir(pane.cwd), 1)[1]
			if first and (not started or first.mtime >= started - 2) then
				path = first.path
			end
		end
		local sess
		local f = path and io.open(path, "rb")
		if f then
			local head = f:read("*l") or ""
			f:close()
			local ok, meta = pcall(rex.json.decode, head)
			meta = ok and type(meta) == "table" and meta or {}
			local model, effort = M.model(path)
			local m = type(status.model) == "table" and status.model or {}
			sess = { id = meta.id or U.basename(path):gsub("%.jsonl$", ""), pid = pane.pid, transcript = path,
				cwd = status.cwd or meta.cwd or pane.cwd, model = m.id or model, model_label = m.name or m.id or model,
				effort = status.thinkingLevel or effort, working = status.working == true or nil,
				status = { window = tonumber(m.contextWindow), limits = {} }, started = started }
		end
		cache[key] = { at = now, sess = sess }
		return sess
	end

	--- Whether a subagent's transcript ends with the model's last answer.
	function M.finished(path)
		local f = io.open(path, "rb")
		if not f then
			return false
		end
		local size = f:seek("end")
		f:seek("set", math.max(0, size - 65536))
		local tail = f:read("*a") or ""
		f:close()
		local last
		for reason in tail:gmatch('"stopReason":"(%a+)"') do
			last = reason
		end
		return last ~= nil and last ~= "toolUse"
	end

	--- A subagent's task: the start of the first prompt in its transcript.
	function M.task(path)
		local f = io.open(path, "rb")
		local head = f and f:read(32768) or ""
		if f then
			f:close()
		end
		local text
		for line in head:gmatch("[^\n]+") do
			text = text or line:match('"role":"user","content":%[{"type":"text","text":"(.-)"}%]')
		end
		text = text and text:gsub("\\n", " "):gsub("%[%a+ %a+: [^%]]*%]", ""):gsub("^%s*Task:", ""):gsub("^%s+", "")
		return text and text ~= "" and text:sub(1, 60) or nil
	end

	--- The session's subagents: the run transcripts in the folder named after
	--- its transcript. One that hasn't finished counts as running while its
	--- file moved in the last 10 minutes. `done` holds IDs known finished.
	function M.subagents(sess, now, done)
		if not sess.transcript then
			return {}
		end
		now = now or os.time()
		done = done or {}
		local folder = sess.transcript:gsub("%.jsonl$", "")
		local out = {}
		for _, file in ipairs(newest(folder, 3)) do
			local run, n, name = file.path:match("/([%w%-]+)/run%-(%d+)/([^/]+)%.jsonl$")
			if run then
				local id = run .. "-" .. n
				local finished = done[id] or M.finished(file.path)
				out[#out + 1] = { id = id, transcript = file.path, type = "subagent", description = M.task(file.path) or ("run " .. n),
					finished = finished, running = not finished and now - file.mtime < 600, updated = file.mtime }
			end
		end
		table.sort(out, function(a, b)
			return a.updated < b.updated
		end)
		return out
	end

	return M
end
