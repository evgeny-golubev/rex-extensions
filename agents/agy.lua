-- The Antigravity CLI (agy) adapter. agy keeps each conversation in
-- ~/.gemini/antigravity-cli: a lock file in presence/ while a CLI has it
-- open, and a JSONL transcript under brain/<id>/.system_generated/logs/. A
-- pane's conversation is found in this order:
--   1. the presence lock its agy process holds open, from lsof;
--   2. the last conversation in the pane's directory, from
--      cache/last_conversations.json.
-- agy runs no subagents that it logs. See agents/init.lua for the interface
-- every adapter has.
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
				local model = M.model(transcript)
				sess = { id = id, pid = pane.pid, transcript = transcript, cwd = cwd, model = model, model_label = model,
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
