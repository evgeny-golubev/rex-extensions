-- Reads the copy of an OpenCode session that agents/opencode.lua writes: one
-- line per final message, {type, seq, id, data, parts}, as OpenCode's database
-- holds it, and a {type = "question"} line while a question waits. An
-- assistant message's parts are text, reasoning and tool parts; a tool part
-- has a name and a state with its input, status, content and metadata.
-- `P` is panel.lua's module; see parsers/claude.lua.
--
-- OpenCode keeps permission requests only in memory, so the Gate box stays
-- empty for an OpenCode pane.
return function(P)
	local R = { id = "opencode" }

	local function text_of(content)
		local out = {}
		for _, c in ipairs(type(content) == "table" and content or {}) do
			if type(c) == "table" and c.text then
				out[#out + 1] = c.text
			end
		end
		return table.concat(out, "\n")
	end

	local function created_hunks(content)
		local lines = {}
		local text = tostring(content or ""):gsub("\n$", "")
		if text ~= "" then
			for line in P.each_line(text .. "\n") do
				lines[#lines + 1] = "+" .. line
			end
		end
		return { { oldStart = 0, oldLines = 0, newStart = 1, newLines = #lines, lines = lines } }
	end

	local function turn_ended(state)
		local at = P.epoch(state.at)
		if state.turn.at and at and not state.turn.ms then
			state.turn.ms = math.max(0, at - state.turn.at) * 1000
			state.claude_ms = state.claude_ms + state.turn.ms
		end
	end

	local function questions_of(input)
		local out = {}
		for _, q in ipairs(type(input) == "table" and type(input.questions) == "table" and input.questions or {}) do
			out[#out + 1] = { question = type(q) == "table" and (q.question or q.header) or tostring(q) }
		end
		return out
	end

	--- The files an edit or patch changed, with their hunks.
	local function changed_files(meta)
		local out = {}
		for _, f in ipairs(type(meta) == "table" and type(meta.files) == "table" and meta.files or {}) do
			if type(f) == "table" and (f.file or f.path) then
				out[#out + 1] = { path = f.file or f.path, hunks = P.parsers.codex.hunks(f.patch or f.diff or ""),
					created = f.status == "added" or f.type == "add" }
			end
		end
		return out
	end

	--- A path as an absolute one, against the session's folder.
	local function absolute(state, path)
		path = tostring(path)
		return (path:sub(1, 1) == "/" or not state.root) and path or (state.root .. "/" .. path:gsub("^%./", ""))
	end

	local function tool(state, part)
		local name = tostring(part.name or "")
		local s = type(part.state) == "table" and part.state or {}
		local input = type(s.input) == "table" and s.input or {}
		local meta = type(s.metadata) == "table" and s.metadata or {}
		local failed = s.status == "error"
		local id = tostring(part.id or (state.seq .. ":" .. name))
		state.tools[id] = { name = name, input = input }
		state.waiting[id] = nil
		if failed then
			state.turn.errors = state.turn.errors + 1
		end
		if name == "shell" or name == "bash" then
			local exit = tonumber(meta.exit)
			local bad = failed or (exit ~= nil and exit ~= 0)
			if bad and not failed then
				state.turn.errors = state.turn.errors + 1
			end
			P.command_ran(state, tostring(input.command or ""), bad, (exit and ("exit " .. exit .. ": ") or "") .. text_of(s.content))
		elseif name == "write" and not failed and (input.path or input.filePath) then
			local path = absolute(state, input.path or input.filePath)
			P.add_hunks(state, path, created_hunks(input.content), true)
			state.turn.edits = state.turn.edits + 1
			P.log(state, "main", "Write → " .. P.short_path(path, state.root))
		elseif (name == "edit" or name == "patch" or name == "apply_patch") and not failed then
			for _, f in ipairs(changed_files(meta)) do
				local path = absolute(state, f.path)
				P.add_hunks(state, path, f.hunks, f.created)
				state.turn.edits = state.turn.edits + 1
				P.log(state, "main", (f.created and "Write" or "Edit") .. " → " .. P.short_path(path, state.root))
			end
		elseif name == "subagent" or name == "task" then
			state.turn.agents = state.turn.agents + 1
			P.log(state, "agent", "done · " .. tostring(input.description or input.agent or "subagent"))
		end
	end

	local function assistant(state, d, parts)
		state.requests = state.requests + 1
		local model = type(d.model) == "table" and d.model or {}
		state.model = model.id or state.model
		state.effort = model.variant or state.effort
		local t = type(d.tokens) == "table" and d.tokens or {}
		local cache = type(t.cache) == "table" and t.cache or {}
		local context = (tonumber(t.input) or 0) + (tonumber(cache.read) or 0) + (tonumber(cache.write) or 0)
		if context > 0 then
			state.context = context
		end
		local tools = 0
		for _, part in ipairs(#parts > 0 and parts or (type(d.content) == "table" and d.content or {})) do
			if part.type == "text" and type(part.text) == "string" and part.text:match("%S") then
				P.reply(state, part.text)
			elseif part.type == "tool" then
				tools = tools + 1
				tool(state, part)
			end
		end
		if tools == 0 then
			turn_ended(state)
		end
	end

	--- Adds one line of the copy to the state.
	function R.record(state, r)
		state.seq = state.seq + 1
		local d = type(r.data) == "table" and r.data or {}
		local t = type(d.time) == "table" and d.time or {}
		local at = tonumber(t.completed or t.created)
		if at then
			state.at = os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(at / 1000))
		end
		local parts = type(r.parts) == "table" and r.parts or {}
		if r.type == "session" then
			state.root = d.directory or state.root
		elseif r.type == "user" then
			state.waiting = {}
			local text = tostring(d.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
			if text ~= "" then
				P.add_prompt(state, text)
			end
		elseif r.type == "assistant" then
			assistant(state, d, parts)
		elseif r.type == "shell" then
			local exit = tonumber(d.exit)
			P.command_ran(state, tostring(d.command or ""), exit ~= nil and exit ~= 0, tostring(d.output or ""))
		elseif r.type == "compaction" then
			state.compactions = state.compactions + 1
		elseif r.type == "question" then
			local s = type(d.state) == "table" and d.state or {}
			local id = tostring(d.id or r.id)
			state.tools[id] = { name = "AskUserQuestion", input = { questions = questions_of(s.input) } }
			state.waiting[id] = true
		end
	end

	function R.skip()
		return false
	end

	--- Adds one line of a subagent's copy to it.
	function R.agent_record(a, r)
		local d = type(r.data) == "table" and r.data or {}
		local t = type(d.time) == "table" and d.time or {}
		local at = tonumber(t.completed or t.created)
		if at then
			a.start = a.start or at / 1000
			a.last = at / 1000
		end
		if r.type ~= "assistant" then
			return
		end
		a.steps = a.steps + 1
		local model = type(d.model) == "table" and d.model or {}
		a.model = model.id or a.model
		local tk = type(d.tokens) == "table" and d.tokens or {}
		local cache = type(tk.cache) == "table" and tk.cache or {}
		local context = (tonumber(tk.input) or 0) + (tonumber(cache.read) or 0) + (tonumber(cache.write) or 0)
		if context > 0 then
			a.context = context
		end
		for _, part in ipairs(type(r.parts) == "table" and r.parts or {}) do
			if part.type == "tool" then
				local s = type(part.state) == "table" and part.state or {}
				a.calls[tostring(part.id)] = { name = part.name, input = s.input }
				P.agent_tool(a, part.name, P.tool_target(part.name, s.input))
			elseif part.type == "text" and type(part.text) == "string" and part.text:match("%S") then
				a.answer = part.text
			end
		end
	end

	--- The final reply in each of the last n turns, newest first.
	function R.turns(lines, n)
		local turns, current = {}, nil
		for i = #lines, 1, -1 do
			local ok, r = pcall(rex.json.decode, lines[i])
			r = ok and type(r) == "table" and r or {}
			if r.type == "assistant" and not current then
				local texts = {}
				for _, part in ipairs(type(r.parts) == "table" and r.parts or {}) do
					if part.type == "text" and type(part.text) == "string" then
						texts[#texts + 1] = part.text
					end
				end
				local text = table.concat(texts, "\n")
				if text:match("%S") then
					current = text
				end
			elseif r.type == "user" then
				if current then
					turns[#turns + 1] = current
					current = nil
				end
				if #turns >= n then
					break
				end
			end
		end
		if current and #turns < n then
			turns[#turns + 1] = current
		end
		return turns
	end

	return R
end
