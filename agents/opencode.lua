-- The OpenCode adapter (OpenCode 2.x). OpenCode keeps its sessions in a SQLite
-- database, ~/.local/share/opencode/opencode.db, which a background service
-- writes; a TUI is only its client, so nothing links a process to a session.
-- A pane's session is:
--   1. the one named with --session or -s on its command line;
--   2. else the newest top-level session in the pane's directory that changed
--      since this opencode started.
-- The sidecar reads transcripts from JSONL files, so the session's messages
-- are copied, once each is final, to ~/.config/rex/state/opencode/<id>.jsonl;
-- see M.sync. Subagents are child sessions. See agents/init.lua.
return function(U)
	local M = { id = "opencode", name = "OpenCode" }

	M.cache_ttl = 3

	function M.db()
		local custom = os.getenv("OPENCODE_DB")
		if custom and custom ~= "" then
			return custom
		end
		local data = os.getenv("XDG_DATA_HOME")
		return ((data and data ~= "") and data or U.home .. "/.local/share") .. "/opencode/opencode.db"
	end

	function M.state_dir()
		return U.home .. "/.config/rex/state/opencode"
	end

	function M.matches(p)
		if p == nil or p.argv0 == nil then
			return false
		end
		local name = U.basename(p.argv0):lower()
		return name == "opencode" or name == ".opencode"
	end

	--- The session ID given with --session or -s on a command line, or nil.
	function M.session_arg(args)
		args = " " .. tostring(args or "") .. " "
		return args:match("%s%-%-session[= ]+(ses_[%w]+)") or args:match("%s%-s[= ]+(ses_[%w]+)")
	end

	local function query(sql)
		return U.sqlite(M.db(), sql)
	end

	local function decode(text)
		local ok, value = pcall(rex.json.decode, tostring(text or ""))
		return ok and type(value) == "table" and value or {}
	end

	--- The context window of a model, from OpenCode's cached models.dev list.
	--- The list is megabytes of JSON, so SQLite picks the one number out.
	local windows = {}
	function M.window(provider, model)
		if not provider or not model then
			return nil
		end
		local key = tostring(provider) .. "/" .. tostring(model)
		if windows[key] == nil then
			local path = '$."' .. tostring(provider):gsub('"', "") .. '".models."' .. tostring(model):gsub('"', "") .. '".limit.context'
			local rows = query("SELECT json_extract(json_extract(value, '$.body'), " .. U.quote(path)
				.. ") AS context FROM kv WHERE key LIKE 'models-dev:%:catalog' ORDER BY key DESC LIMIT 1") or {}
			windows[key] = rows[1] and tonumber(rows[1].context) or false
		end
		return windows[key] or nil
	end

	local columns = "id, directory, title, model, agent, time_updated, time_busy, time_idle"

	local function row_session(row, pane, started)
		local model = decode(row.model)
		local busy, idle = tonumber(row.time_busy) or 0, tonumber(row.time_idle) or 0
		return {
			id = row.id,
			pid = pane.pid,
			cwd = row.directory or pane.cwd,
			name = row.title,
			started = started,
			working = busy > idle,
			model = model.id,
			model_label = model.id,
			effort = model.variant,
			status = { window = M.window(model.providerID, model.id), limits = {} },
		}
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
		local id = M.session_arg(U.args(pane.pid))
		local where = id and ("id = " .. U.quote(id))
			or ("directory = " .. U.quote(pane.cwd or "") .. " AND parent_id IS NULL AND time_archived IS NULL")
		local rows = query("SELECT " .. columns .. " FROM session_v2 WHERE " .. where .. " ORDER BY time_updated DESC LIMIT 1") or {}
		local row = rows[1]
		if row and not id and started and (tonumber(row.time_updated) or 0) / 1000 < started - 2 then
			row = nil
		end
		local sess = row and row_session(row, pane, started)
		if sess then
			sess.transcript = M.sync(sess.id, sess.cwd, row.time_updated)
		end
		cache[key] = { at = now, sess = sess }
		return sess
	end

	--- A tool part waiting for an answer, from an unfinished message's parts.
	local function pending_question(parts)
		for _, part in ipairs(parts) do
			local d = decode(part.data)
			d.type = d.type or part.type
			local state = type(d.state) == "table" and d.state or {}
			if d.name == "question" and state.status ~= "completed" and state.status ~= "error" then
				return d
			end
		end
	end

	--- One line of the copy: the message's own JSON and its parts', as the
	--- database holds them, so every process writes the same text.
	function M.line(row, parts)
		local out = {}
		for _, part in ipairs(parts) do
			local data = tostring(part.data or "{}")
			-- The part's type is a column of its own, and may be left out of its data.
			if part.type and not data:find('^{"type":') then
				data = '{"type":' .. rex.json.encode(tostring(part.type)) .. (data == "{}" and "}" or ("," .. data:sub(2)))
			end
			out[#out + 1] = data
		end
		return '{"type":' .. rex.json.encode(tostring(row.type)) .. ',"seq":' .. tostring(row.seq) .. ',"id":'
			.. rex.json.encode(tostring(row.id)) .. ',"data":' .. (row.data or "{}") .. ',"parts":[' .. table.concat(out, ",") .. "]}"
	end

	--- Whether a message is final: an assistant message once it completed or
	--- failed, any other at once.
	function M.final(row)
		if row.type ~= "assistant" then
			return true
		end
		local d = decode(row.data)
		return (type(d.time) == "table" and d.time.completed ~= nil) or d.error ~= nil
	end

	--- The last seq and question already copied, from the copy's last line.
	local function tail_of(path)
		local f = io.open(path, "rb")
		if not f then
			return 0
		end
		local size = f:seek("end")
		f:seek("set", math.max(0, size - 65536))
		local tail = f:read("*a") or ""
		f:close()
		local last = tail:match("([^\n]+)\n?$") or ""
		local seq = tonumber(last:match('^{"type":"[^"]*","seq":(%d+)')) or 0
		return seq, last:match('^{"type":"question","seq":%d+,"id":"([^"]+)"')
	end

	--- Copies the session's new final messages to its JSONL file, and a
	--- question it waits on, and returns the file's path. A lock folder keeps
	--- two processes (a sidecar and the pond) from adding the same lines.
	--- The time_updated each session was last copied at, so an unchanged one
	--- isn't queried again; and whether old copies were cleared this run.
	local synced, pruned = {}, false

	function M.sync(id, directory, updated)
		local dir = M.state_dir()
		local path = dir .. "/" .. id .. ".jsonl"
		if updated and synced[id] == updated then
			return path
		end
		if not pruned then
			pruned = true
			U.exec({ "/usr/bin/find", dir, "-name", "*.jsonl", "-mtime", "+30", "-delete" })
		end
		local lock = path .. ".lock"
		U.exec({ "/bin/mkdir", "-p", dir })
		if not (U.exec({ "/bin/mkdir", lock }) or {}).ok then
			local r = U.exec({ "/usr/bin/find", lock, "-maxdepth", "0", "-mmin", "+1" })
			if r and r.ok and r.stdout:match("%S") then
				U.exec({ "/bin/rmdir", lock })
			end
			return path
		end
		-- No pcall here: the sidecar's exec yields, which Lua 5.1 can't inside one.
		local function copy()
			local seq, question = tail_of(path)
			local lines = {}
			if seq == 0 and directory and not io.open(path, "rb") then
				lines[1] = '{"type":"session","seq":0,"id":' .. rex.json.encode(id) .. ',"data":{"directory":' .. rex.json.encode(directory) .. "}}"
			end
			local rows = query("SELECT id, type, seq, data FROM session_message WHERE session_id = " .. U.quote(id)
				.. " AND seq > " .. seq .. " ORDER BY seq LIMIT 500") or {}
			if #rows == 0 and #lines == 0 then
				return
			end
			local ids = {}
			for _, row in ipairs(rows) do
				ids[#ids + 1] = U.quote(row.id)
			end
			local parts = {}
			for _, p in ipairs(query("SELECT message_id, type, data FROM session_part WHERE message_id IN (" .. table.concat(ids, ",")
				.. ") ORDER BY message_id, ordinal") or {}) do
				parts[p.message_id] = parts[p.message_id] or {}
				table.insert(parts[p.message_id], p)
			end
			for _, row in ipairs(rows) do
				local own = parts[row.id] or {}
				if not M.final(row) then
					local q = pending_question(own)
					if q and q.id ~= question then
						lines[#lines + 1] = '{"type":"question","seq":' .. seq .. ',"id":' .. rex.json.encode(tostring(q.id))
							.. ',"data":' .. rex.json.encode(q) .. "}"
					end
					break
				end
				lines[#lines + 1] = M.line(row, own)
				seq = row.seq
			end
			local f = #lines > 0 and io.open(path, "ab")
			if f then
				f:write(table.concat(lines, "\n"), "\n")
				f:close()
			end
		end
		copy()
		U.exec({ "/bin/rmdir", lock })
		synced[id] = updated
		return path
	end

	--- The session's subagents: its child sessions. A child counts as
	--- finished once it went idle after its last busy spell.
	function M.subagents(sess, _, done)
		local rows = query("SELECT id, title, agent, time_created, time_updated, time_busy, time_idle FROM session_v2 WHERE parent_id = "
			.. U.quote(sess.id) .. " ORDER BY time_created") or {}
		done = done or {}
		local out = {}
		for _, row in ipairs(rows) do
			local busy, idle = tonumber(row.time_busy) or 0, tonumber(row.time_idle) or 0
			local finished = done[row.id] or idle >= busy and idle > 0
			out[#out + 1] = {
				id = row.id,
				transcript = done[row.id] and (M.state_dir() .. "/" .. row.id .. ".jsonl") or M.sync(row.id, nil, row.time_updated),
				type = row.agent,
				description = row.title,
				finished = finished,
				running = not finished,
				started = tonumber(row.time_created) and row.time_created / 1000 or nil,
				updated = tonumber(row.time_updated) and row.time_updated / 1000 or nil,
			}
		end
		return out
	end

	return M
end
