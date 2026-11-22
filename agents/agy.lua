-- The Antigravity CLI (agy) adapter. agy keeps each conversation in
-- ~/.gemini/antigravity-cli: a lock file in presence/ while a CLI has it
-- open, and a JSONL transcript under brain/<id>/.system_generated/logs/. A
-- pane's conversation is found in this order:
--   1. the presence lock its agy process holds open, from lsof;
--   2. the last conversation in the pane's directory, from
--      cache/last_conversations.json.
-- The model's effort, the context window and the usage quota come from agy's
-- status line input, which agents/agy-statusline.sh saves to
-- state/statusline/<conversation>.json. agy runs no subagents that it logs.
-- See agents/init.lua for the interface every adapter has.
return function(U)
	local M = { id = "agy", name = "Antigravity" }

	--- How long a pane's session lookup is reused, in seconds.
	M.cache_ttl = 5

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

	--- The context window and the 5-hour and weekly quota from a status line
	--- input. Gemini models draw on the gemini buckets, others on the 3p ones.
	function M.status(sl)
		local out = { limits = {} }
		local window = type(sl.context_window) == "table" and tonumber(sl.context_window.context_window_size)
		out.window = window
		local model = type(sl.model) == "table" and tostring(sl.model.id or sl.model.display_name or "") or ""
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
		local r = U.exec({ "/usr/sbin/lsof", "-p", tostring(pane.pid), "-Fn" })
		local id = r and r.ok and M.locked_id(r.stdout) or nil
		local cwd = pane.cwd
		if not id then
			local last = U.read_json(M.home() .. "/cache/last_conversations.json")
			id = type(last) == "table" and type(last[cwd or ""]) == "string" and last[cwd] or nil
		end
		local sess
		if id and id:match("^[%w%-]+$") then
			local transcript = M.transcript(id)
			local f = io.open(transcript, "rb")
			if f then
				f:close()
				local sl = U.read_json(M.home() .. "/state/statusline/" .. id .. ".json") or {}
				local m = type(sl.model) == "table" and sl.model or {}
				local model = m.id or M.model(transcript)
				sess = { id = id, pid = pane.pid, transcript = transcript, cwd = cwd, model = model,
					model_label = m.display_name or model, effort = m.effort, status = M.status(sl),
					started = U.started(pane.pid, now) }
			end
		end
		cache[key] = { at = now, sess = sess }
		return sess
	end

	function M.subagents()
		return {}
	end

	return M
end
