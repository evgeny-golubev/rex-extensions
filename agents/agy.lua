-- The Antigravity CLI (agy) adapter. agy keeps each conversation in
-- ~/.gemini/antigravity-cli: a lock file in presence/ while a CLI has it
-- open, and a JSONL transcript under brain/<id>/.system_generated/logs/. A
-- pane's conversation is found in this order:
--   1. the presence lock its agy process holds open, from lsof;
--   2. the last conversation in the pane's directory, from
--      cache/last_conversations.json, if written since agy started: a new
--      agy has none until its first prompt.
-- The model's effort, the context window and the usage quota come from agy's
-- status line input, which agents/agy-statusline.sh saves to
-- state/statusline/<conversation>.json. Conversation titles and subagents
-- come from conversation_summaries.db.
-- See agents/init.lua for the interface every adapter has.
return function(U)
	local M = {
		id = "agy",
		name = "Antigravity",
		theme = {
			accent = "#4285F4", -- Google Blue
			agent = "#8AB4F8", -- Light Blue
			clock = "#4285F4",
			gradient = { "#4285F4", "#EA4335", "#FBBC05", "#34A853" },
		},
	}

	--- How long a pane's session lookup is reused, in seconds.
	M.cache_ttl = 5

	local EFFORTS = { low = true, medium = true, high = true, xhigh = true, max = true }

	function M.home()
		return U.home .. "/.gemini/antigravity-cli"
	end

	function M.matches(p)
		return p ~= nil and p.argv0 ~= nil and U.basename(p.argv0):lower() == "agy"
	end

	--- The conversation whose presence lock appears in `lsof -Fn` output.
	function M.locked_id(lsof)
		for path in tostring(lsof or ""):gmatch("n([^\n]+)") do
			local id = path:match("/presence/([%w%-]+)%.lock$")
			if id then
				return id
			end
		end
	end

	function M.transcript(id)
		return M.home() .. "/brain/" .. id .. "/.system_generated/logs/transcript_full.jsonl"
	end

	--- The effort suffix encoded at the end of a model ID (e.g. gemini-4-neon-high).
	function M.model_effort(model)
		local suffix = tostring(model or ""):match("%-(%a+)$")
		if suffix and EFFORTS[suffix:lower()] then
			return suffix:lower()
		end
	end

	--- The model of the latest model step, from the end of a transcript.
	function M.model(path)
		local f = io.open(path, "rb")
		if not f then
			return nil
		end
		local size = f:seek("end")
		f:seek("set", math.max(0, size - 65536))
		local tail = f:read("*a") or ""
		f:close()
		local model
		for m in tail:gmatch('"model":"([^"]+)"') do
			model = m
		end
		return model
	end

	--- Reads rows from conversation_summaries.db with sqlite3 -json, or nil.
	local function query_db(sql)
		local db = M.home() .. "/conversation_summaries.db"
		local f = io.open(db, "rb")
		if not f then
			return nil
		end
		f:close()
		local r = U.exec({ "/usr/bin/sqlite3", "-readonly", "-json", db, sql })
		if not (r and r.ok and r.stdout and r.stdout:match("%S")) then
			return nil
		end
		local ok, rows = pcall(rex.json.decode, r.stdout)
		return ok and type(rows) == "table" and rows or nil
	end

	--- The conversation's title from conversation_summaries.db, or nil.
	function M.title(id)
		if not (id and id:match("^[%w%-]+$")) then
			return nil
		end
		local rows = query_db("SELECT title FROM conversation_summaries WHERE conversation_id = '" .. id .. "' LIMIT 1")
		local t = rows and rows[1] and rows[1].title
		return type(t) == "string" and t:match("%S") and t or nil
	end

	--- Seconds since 1970 of a UTC time written as YYYY-MM-DDTHH:MM:SSZ.
	local function utc(text)
		local y, mo, d, h, mi, sec = tostring(text or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
		if not y then
			return nil
		end
		local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(sec) })
		local now = os.time()
		return t + os.difftime(now, os.time(os.date("!*t", now)))
	end

	--- Default context window size when status line input hasn't reported one yet.
	local function default_window(model)
		local lower = tostring(model or ""):lower()
		if lower:find("gemini", 1, true) then
			return 1048576
		end
		return nil
	end

	--- The context window and the 5-hour and weekly quota from a status line
	--- input. Gemini models draw on the gemini buckets, others on the 3p ones.
	function M.status(sl, fallback_model)
		local out = { limits = {} }
		local model = type(sl.model) == "table" and tostring(sl.model.id or sl.model.display_name or "") or tostring(fallback_model or "")
		local window = type(sl.context_window) == "table" and tonumber(sl.context_window.context_window_size)
		out.window = window or default_window(model)
		local family = model:lower():find("gemini", 1, true) and "gemini" or "3p"
		local quota = type(sl.quota) == "table" and sl.quota or {}
		for _, w in ipairs({ { "5h", quota[family .. "-5h"] }, { "7d", quota[family .. "-weekly"] } }) do
			local q = w[2]
			if type(q) == "table" and tonumber(q.remaining_fraction) then
				out.limits[#out.limits + 1] = { label = w[1], used = (1 - tonumber(q.remaining_fraction)) * 100, resets_at = utc(q.reset_time) }
			end
		end
		return out
	end

	local cache = {}

	function M.session(pane)
		local key = tostring(pane.pid) .. "\0" .. tostring(pane.cwd)
		local now = os.time()
		local hit = cache[key]
		if hit and now - hit.at < M.cache_ttl then
			return hit.sess
		end
		local r = U.exec({ "/usr/sbin/lsof", "-p", tostring(pane.pid), "-n", "-P", "-Fn" })
		local id = r and r.ok and M.locked_id(r.stdout) or nil
		local cwd = pane.cwd
		local started = U.started(pane.pid, now)
		local locked = id ~= nil
		if not id then
			local last = U.read_json(M.home() .. "/cache/last_conversations.json")
			id = type(last) == "table" and type(last[cwd or ""]) == "string" and last[cwd] or nil
		end
		local sess
		if id and id:match("^[%w%-]+$") and not locked then
			local st = U.exec({ "/usr/bin/stat", "-f", "%m", M.transcript(id) })
			local mtime = st and st.ok and tonumber(st.stdout:match("%d+"))
			if not (mtime and started and mtime >= started - 2) then
				id = nil
			end
		end
		if id and id:match("^[%w%-]+$") then
			local transcript = M.transcript(id)
			local f = io.open(transcript, "rb")
			if f then
				f:close()
				local sl = U.read_json(M.home() .. "/state/statusline/" .. id .. ".json") or {}
				local m = type(sl.model) == "table" and sl.model or {}
				local model = m.id or M.model(transcript)
				local effort = m.effort or M.model_effort(model)
				local title = type(sl.conversation_title) == "string" and sl.conversation_title:match("%S") and sl.conversation_title
					or M.title(id)
				local mode = type(sl.cycle_mode) == "string" and sl.cycle_mode ~= "" and sl.cycle_mode or nil
				sess = {
					id = id,
					pid = pane.pid,
					transcript = transcript,
					cwd = cwd,
					name = title,
					model = model,
					model_label = m.display_name or model,
					effort = effort,
					mode = mode,
					status = M.status(sl, model),
					started = started,
				}
			end
		end
		cache[key] = { at = now, sess = sess }
		return sess
	end

	function M.subagents(sess)
		local id = sess and sess.id
		if not (id and id:match("^[%w%-]+$")) then
			return {}
		end
		local rows = query_db(
			"SELECT conversation_id, agent_name, status, title FROM conversation_summaries "
				.. "WHERE parent_conversation_id = '" .. id .. "' ORDER BY last_modified_time"
		)
		if not rows then
			return {}
		end
		local out = {}
		for _, row in ipairs(rows) do
			local sub_id = row.conversation_id
			if type(sub_id) == "string" and sub_id:match("^[%w%-]+$") then
				local transcript = M.transcript(sub_id)
				local f = io.open(transcript, "rb")
				if f then
					f:close()
					local kind = type(row.agent_name) == "string" and row.agent_name ~= "" and row.agent_name or "subagent"
					local desc = type(row.title) == "string" and row.title ~= "" and row.title or nil
					out[#out + 1] = {
						id = sub_id,
						type = kind,
						description = desc,
						transcript = transcript,
						finished = row.status ~= "CASCADE_RUN_STATUS_RUNNING",
						running = row.status == "CASCADE_RUN_STATUS_RUNNING",
					}
				end
			end
		end
		return out
	end

	return M
end
