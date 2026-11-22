-- The Codex adapter. A Codex TUI doesn't record which thread it shows, and
-- its threads run in a shared app-server, so a pane's thread is found in
-- Codex's state database (~/.codex/state_N.sqlite), in this order:
--   1. the thread named in the pane's title, which Codex sets to
--      "<thread name> | <folder>";
--   2. the thread in `codex resume <id>`;
--   3. the latest thread in the pane's directory created after the process
--      started.
-- See agents/init.lua for the interface every adapter has.
return function(U)
	local M = { id = "codex", name = "Codex" }

	local terminal = "com.superlogical.terminal"
	--- A subagent whose thread moved within this many seconds is running.
	M.running_window = 300
	--- How long a pane's session lookup is reused, in seconds.
	M.cache_ttl = 5

	function M.home()
		local custom = os.getenv("CODEX_HOME")
		return (custom and custom ~= "") and custom or (U.home .. "/.codex")
	end

	function M.matches(p)
		return p ~= nil and p.argv0 ~= nil and U.basename(p.argv0):lower() == "codex"
	end

	--- The newest state database in a folder listing, as Codex numbers them.
	function M.pick_db(listing)
		local best, version
		for name in tostring(listing or ""):gmatch("[^\n]+") do
			local digits = name:match("^state_(%d+)%.sqlite$")
			local n = digits and tonumber(digits)
			if n and (not version or n > version) then
				best, version = name, n
			end
		end
		return best
	end

	--- The state database, looked for again a minute after it wasn't found,
	--- as when Codex is installed while a pane runs.
	local db = { at = -math.huge }
	function M.db(now)
		now = now or os.time()
		if not db.path and now - db.at >= 60 then
			local r = U.exec({ "/bin/ls", M.home() })
			local name = r and r.ok and M.pick_db(r.stdout)
			db = { at = now, path = name and (M.home() .. "/" .. name) or nil }
		end
		return db.path
	end

	--- Strips the braille spinner (U+2800 to U+28FF) Codex puts before its
	--- title while it works, and spaces.
	local function strip_spinner(text)
		while true do
			local rest = text:gsub("^%s+", ""):gsub("^\226[\160-\163][\128-\191]", "")
			if rest == text then
				return text
			end
			text = rest
		end
	end

	--- The thread name in a Codex terminal title, without the " | folder"
	--- after it or a spinner before it, and whether Codex cut it short with
	--- "..." (then it's the start of the name).
	function M.title_name(title)
		local name = strip_spinner((tostring(title or ""):gsub("%s+|%s+[^|]*$", ""))):gsub("%s+$", "")
		local cut = false
		for _, ellipsis in ipairs({ "...", "…" }) do
			if name:sub(-#ellipsis) == ellipsis then
				name, cut = name:sub(1, -#ellipsis - 1):gsub("%s+$", ""), true
				break
			end
		end
		if name == "" or name:lower() == "codex" then
			return nil
		end
		return name, cut
	end

	--- The thread ID in a `codex resume <id>` command line.
	function M.resume_id(args)
		return tostring(args or ""):match("%sresume%s+(%x+%-%x+%-%x+%-%x+%-%x+)")
	end

	local columns = "id, rollout_path, cwd, name, model, reasoning_effort, created_at, updated_at"
	-- A pane shows only interactive threads: subagent and reviewer threads
	-- have a JSON source, and `codex exec` runs, as Symphony's, an exec one.
	local top_level = " from threads where archived = 0 and source not like '{%' and source <> 'exec'"
		.. " and coalesce(originator, '') <> 'codex_exec'"

	local function query(db, where, limit)
		return U.sqlite(db, "select " .. columns .. top_level .. " and " .. where .. " order by updated_at desc limit " .. limit) or {}
	end

	local function first(db, where)
		return query(db, where, 1)[1]
	end

	--- The pane's thread row, by the steps at the top of this file.
	function M.find_thread(db, pane)
		local name, cut = M.title_name(pane.title)
		if name then
			local named = cut and ("instr(name, " .. U.quote(name) .. ") = 1") or ("name = " .. U.quote(name))
			local row = pane.cwd and first(db, named .. " and cwd = " .. U.quote(pane.cwd))
			-- A whole name is rare enough to find anywhere, as after /cd; the
			-- start of one could be another project's.
			if not row and not cut then
				row = first(db, named)
			end
			if row then
				return row
			end
		end
		local id = M.resume_id(pane.args or U.args(pane.pid))
		if id then
			local row = first(db, "id = " .. U.quote(id))
			if row then
				return row
			end
		end
		local started = pane.started or U.started(pane.pid)
		if started and pane.cwd then
			-- Two threads could be this pane's or another's that started in
			-- the same folder; no guess then, until Codex names the thread.
			local rows = query(db, "cwd = " .. U.quote(pane.cwd) .. " and created_at >= " .. math.floor(started - 5), 2)
			return #rows == 1 and rows[1] or nil
		end
	end

	--- "5h" or "7d" for a limit's window in minutes.
	function M.window_label(minutes)
		minutes = tonumber(minutes)
		if not minutes then
			return "limit"
		elseif minutes % 1440 == 0 then
			return math.floor(minutes / 1440) .. "d"
		elseif minutes % 60 == 0 then
			return math.floor(minutes / 60) .. "h"
		end
		return minutes .. "m"
	end

	--- Usage limits in the shape agents/init.lua describes, from a
	--- token_count event's rate_limits.
	function M.limits(rate_limits)
		local out = {}
		for _, key in ipairs({ "primary", "secondary" }) do
			local l = type(rate_limits) == "table" and rate_limits[key] or nil
			if type(l) == "table" and tonumber(l.used_percent) then
				out[#out + 1] = { label = M.window_label(l.window_minutes), used = tonumber(l.used_percent), resets_at = tonumber(l.resets_at) }
			end
		end
		return out
	end

	--- The last rate_limits in the end of a rollout, or nil.
	function M.last_rate_limits(path)
		local f = path and io.open(path, "rb")
		if not f then
			return nil
		end
		local size = f:seek("end")
		f:seek("set", math.max(0, size - 262144))
		local text = f:read("*a") or ""
		f:close()
		local last
		local pos = 1
		while true do
			local at = text:find('"type":"token_count"', pos, true)
			if not at then
				break
			end
			last, pos = at, at + 1
		end
		if not last then
			return nil
		end
		local from = 1
		local i = text:find("\n", 1, true)
		while i and i < last do
			from = i + 1
			i = text:find("\n", i + 1, true)
		end
		local ok, r = pcall(rex.json.decode, text:sub(from, (i or (#text + 1)) - 1))
		local p = ok and type(r) == "table" and r.payload
		return type(p) == "table" and p.rate_limits or nil
	end

	--- Usage limits are the account's, so they're read from the thread that
	--- changed last, whichever it is: an idle pane's own rollout has old ones.
	local limits_cache = { at = 0 }
	function M.latest_limits(now)
		now = now or os.time()
		if now - limits_cache.at < 30 then
			return limits_cache.limits
		end
		local db = M.db()
		local rows = db and U.sqlite(db, "select rollout_path from threads order by updated_at desc limit 1")
		local path = rows and rows[1] and rows[1].rollout_path
		limits_cache = { at = now, limits = M.limits(M.last_rate_limits(path)) }
		return limits_cache.limits
	end

	local cache = {}

	function M.session(pane)
		local title = pane.title
		if title == nil and pane.session_id and pane.block_id then
			local ok, t = pcall(rex.block.call, terminal, "title", { session_id = pane.session_id, block_id = pane.block_id })
			title = ok and t and t.title or nil
			pane.title = title
		end
		-- Keyed by the name, not the title, whose spinner moves while Codex works.
		local key = tostring(pane.pid) .. "\0" .. tostring(M.title_name(title)) .. "\0" .. tostring(pane.cwd)
		local now = os.time()
		local hit = cache[key]
		if hit and now - hit.at < M.cache_ttl then
			return hit.sess
		end
		local path = M.db(now)
		pane.started = pane.started or U.started(pane.pid, now)
		local row = path and M.find_thread(path, pane)
		local sess = row and {
			id = row.id,
			pid = pane.pid,
			transcript = row.rollout_path,
			cwd = row.cwd,
			name = (row.name and row.name ~= "") and row.name or nil,
			-- Uptime is the program's, as Claude's is; a resumed thread is older.
			started = pane.started or tonumber(row.created_at),
			model = row.model,
			model_label = row.model,
			effort = row.reasoning_effort,
			status = { limits = M.latest_limits(now) },
		} or nil
		cache[key] = { at = now, sess = sess }
		return sess
	end

	--- The threads this one spawned, oldest first, looked up again after a
	--- few seconds. Their spawn edges stay open, so one runs while its thread
	--- keeps changing; the parent's rollout says when it finished.
	local spawned = {}
	function M.subagents(sess, now)
		now = now or os.time()
		local hit = spawned[sess.id]
		if hit and now - hit.at < M.cache_ttl then
			return hit.list
		end
		local db = M.db(now)
		local rows = db and U.sqlite(db, "select t.id, t.rollout_path, t.agent_path, t.agent_nickname, t.agent_role, t.model,"
			.. " t.created_at, t.updated_at from thread_spawn_edges e join threads t on t.id = e.child_thread_id"
			.. " where e.parent_thread_id = " .. U.quote(sess.id) .. " order by t.created_at") or {}
		local out = {}
		for _, row in ipairs(rows) do
			local path = row.agent_path and row.agent_path ~= "" and U.basename(row.agent_path) or nil
			local updated = tonumber(row.updated_at)
			out[#out + 1] = {
				id = row.id,
				transcript = row.rollout_path,
				type = row.agent_role or row.agent_nickname,
				description = path and path:gsub("_", " ") or row.agent_nickname,
				model = row.model,
				started = tonumber(row.created_at),
				updated = updated,
				finished = false,
				running = updated ~= nil and now - updated <= M.running_window,
			}
		end
		spawned[sess.id] = { at = now, list = out }
		return out
	end

	return M
end
