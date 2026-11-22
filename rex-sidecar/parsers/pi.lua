-- Reads a Pi session transcript into the panel's state. Each line is a record;
-- the conversation is in "message" records, whose message.role is user,
-- assistant or toolResult. An assistant message holds text, thinking and
-- toolCall parts; each call's result is a toolResult message with the call's
-- ID. `P` is panel.lua's module; see parsers/claude.lua.
--
-- Pi logs no permission decisions, so the Gate box stays empty for a Pi pane.
return function(P)
	local R = { id = "pi" }

	--- The prompt as the panel lists it: a loaded skill by its name.
	function R.prompt_text(text)
		text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
		local skill = text:match('^<skill name="([^"]+)"')
		if skill then
			return "/skill:" .. skill
		elseif text == "" or text:sub(1, 1) == "<" then
			return nil
		end
		return text
	end

	local function texts(content)
		if type(content) == "string" then
			return content
		end
		local out = {}
		for _, part in ipairs(type(content) == "table" and content or {}) do
			if type(part) == "table" and part.type == "text" and part.text then
				out[#out + 1] = part.text
			end
		end
		return table.concat(out, "\n")
	end

	--- The hunks of Pi's edit diff. Each line is a sign, a line number and the
	--- text; removed and unchanged lines carry the old file's numbers, added
	--- lines the new file's, and "..." separates the hunks.
	function R.diff_hunks(diff)
		local hunks, hunk, delta = {}, nil, 0
		local function close()
			if hunk and #hunk.lines > 0 then
				hunk.oldStart = hunk.oldStart or math.max(0, hunk.newStart - delta)
				hunk.newStart = hunk.newStart or (hunk.oldStart + delta)
				hunks[#hunks + 1] = hunk
				delta = delta + hunk.newLines - hunk.oldLines
			end
			hunk = nil
		end
		for line in P.each_line(tostring(diff or "") .. "\n") do
			local sign, n, text = line:match("^([ +%-])%s*(%d+) (.*)$")
			if not sign then
				sign, n = line:match("^([ +%-])%s*(%d+)$")
				text = ""
			end
			if sign then
				hunk = hunk or { oldLines = 0, newLines = 0, lines = {} }
				n = tonumber(n)
				if sign == "+" then
					-- Only a hunk that starts with an added line has no old number.
					if #hunk.lines == 0 then
						hunk.newStart = n
					end
					hunk.newLines = hunk.newLines + 1
				else
					hunk.oldStart = hunk.oldStart or n
					hunk.oldLines = hunk.oldLines + 1
					if sign == " " then
						hunk.newLines = hunk.newLines + 1
					end
				end
				hunk.lines[#hunk.lines + 1] = sign .. text
			elseif line:match("^%s*%.%.%.%s*$") then
				close()
			end
		end
		close()
		return hunks
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

	local function is_question(name)
		return name == "ask_user" or name == "ask_user_question" or name == "question"
	end

	local function turn_ended(state)
		local at = P.epoch(state.at)
		if state.turn.at and at and not state.turn.ms then
			state.turn.ms = math.max(0, at - state.turn.at) * 1000
			state.claude_ms = state.claude_ms + state.turn.ms
		end
	end

	local function assistant(state, m)
		state.requests = state.requests + 1
		state.model = m.model or state.model
		local u = type(m.usage) == "table" and m.usage or {}
		local context = (tonumber(u.input) or 0) + (tonumber(u.cacheRead) or 0) + (tonumber(u.cacheWrite) or 0)
		if context > 0 then
			state.context = context
		end
		for _, part in ipairs(type(m.content) == "table" and m.content or {}) do
			if part.type == "text" and type(part.text) == "string" and part.text:match("%S") then
				P.reply(state, part.text)
			elseif part.type == "toolCall" and part.id then
				local args = type(part.arguments) == "table" and part.arguments or {}
				local name = tostring(part.name or "")
				state.tools[part.id] = { name = name, input = args }
				if is_question(name) then
					local questions = {}
					local list = type(args.questions) == "table" and args.questions or { args }
					for _, q in ipairs(list) do
						questions[#questions + 1] = { question = type(q) == "table" and (q.question or q.prompt) or tostring(q) }
					end
					state.tools[part.id] = { name = "AskUserQuestion", input = { questions = questions } }
					state.waiting[part.id] = true
				elseif name == "subagent" then
					state.turn.agents = state.turn.agents + 1
					P.log(state, "agent", "started · " .. tostring(args.agent or "subagent"))
				end
			end
		end
		if m.stopReason and m.stopReason ~= "toolUse" then
			turn_ended(state)
		end
	end

	local function tool_result(state, m)
		local tool = state.tools[m.toolCallId]
		if not tool then
			return
		end
		state.waiting[m.toolCallId] = nil
		local failed = m.isError == true
		local input = tool.input or {}
		local details = type(m.details) == "table" and m.details or {}
		if failed then
			state.turn.errors = state.turn.errors + 1
		end
		if tool.name == "bash" then
			P.command_ran(state, tostring(input.command or ""), failed, texts(m.content))
		elseif (tool.name == "edit" or tool.name == "write") and not failed and type(input.path) == "string" then
			local created = tool.name == "write"
			local hunks = created and created_hunks(input.content) or R.diff_hunks(details.diff)
			-- Pi resolves a relative path against its folder.
			local path = (input.path:sub(1, 1) == "/" or not state.root) and input.path or (state.root .. "/" .. input.path:gsub("^%./", ""))
			P.add_hunks(state, path, hunks, created)
			state.turn.edits = state.turn.edits + 1
			P.log(state, "main", (created and "Write" or "Edit") .. " → " .. P.short_path(path, state.root))
		elseif tool.name == "subagent" and not failed then
			P.log(state, "agent", "done · " .. tostring(input.agent or "subagent"))
		end
	end

	--- Adds one transcript record to the state.
	function R.record(state, r)
		state.seq = state.seq + 1
		state.at = r.timestamp or state.at
		if r.type == "session" then
			state.root = r.cwd or state.root
		elseif r.type == "model_change" then
			state.model = r.modelId or state.model
		elseif r.type == "thinking_level_change" then
			state.effort = r.thinkingLevel or state.effort
		elseif r.type == "session_info" and r.name then
			state.title = r.name
		elseif r.type == "compaction" then
			state.compactions = state.compactions + 1
		elseif r.type == "message" and type(r.message) == "table" then
			local m = r.message
			if m.role == "user" then
				-- An answer ends the questions asked before it.
				state.waiting = {}
				local text = R.prompt_text(texts(m.content))
				if text then
					P.add_prompt(state, text)
				end
			elseif m.role == "assistant" then
				assistant(state, m)
			elseif m.role == "toolResult" then
				tool_result(state, m)
			end
		end
	end

	function R.skip()
		return false
	end

	--- Adds one record of a subagent's transcript to it.
	function R.agent_record(a, r)
		local at = P.epoch(r.timestamp)
		if at then
			a.start = a.start or at
			a.last = at
		end
		local m = r.type == "message" and type(r.message) == "table" and r.message or {}
		if m.role == "assistant" then
			a.steps = a.steps + 1
			a.model = m.model or a.model
			local u = type(m.usage) == "table" and m.usage or {}
			local context = (tonumber(u.input) or 0) + (tonumber(u.cacheRead) or 0) + (tonumber(u.cacheWrite) or 0)
			if context > 0 then
				a.context = context
			end
			for _, part in ipairs(type(m.content) == "table" and m.content or {}) do
				if part.type == "toolCall" then
					a.calls[part.id or ""] = { name = part.name, input = part.arguments }
					P.agent_tool(a, part.name, P.tool_target(part.name, part.arguments))
				elseif part.type == "text" and type(part.text) == "string" and part.text:match("%S") then
					a.answer = part.text
				end
			end
		end
	end

	--- The final reply in each of the last n turns, newest first.
	function R.turns(lines, n)
		local turns, current = {}, nil
		for i = #lines, 1, -1 do
			local line = lines[i]
			if line:find('"role":"', 1, true) then
				local ok, r = pcall(rex.json.decode, line)
				local m = ok and type(r) == "table" and type(r.message) == "table" and r.message or {}
				if m.role == "assistant" and not current then
					local text = texts(m.content)
					if text:match("%S") then
						current = text
					end
				elseif m.role == "user" and R.prompt_text(texts(m.content)) then
					if current then
						turns[#turns + 1] = current
						current = nil
					end
					if #turns >= n then
						break
					end
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
