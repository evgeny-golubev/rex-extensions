-- Reads an Antigravity CLI (agy) transcript,
-- brain/<id>/.system_generated/logs/transcript_full.jsonl, into the panel's
-- state. Each line is a step: USER_INPUT holds the prompt inside
-- <USER_REQUEST>; PLANNER_RESPONSE is a model step with its model, tokens,
-- an optional reply and its tool calls; GENERIC steps are the tool results,
-- in the order of the calls. `P` is panel.lua's module; see parsers/claude.lua.
--
-- agy logs no permission decisions and no subagents, so the Gate box,
-- background tasks and agent lanes stay empty for an agy pane. Edits are
-- recognised by the tool's name (write, replace, edit or create) and a file
-- argument, so a tool agy adds later still counts.
return function(P)
	local R = { id = "agy" }

	--- The prompt the person typed, without the metadata agy adds around it.
	function R.prompt_text(content)
		content = tostring(content or "")
		return content:match("<USER_REQUEST>%s*(.-)%s*</USER_REQUEST>") or content
	end

	--- The file an edit tool's arguments name, or nil.
	local function edit_path(args)
		for _, key in ipairs({ "TargetFile", "AbsolutePath", "FilePath", "File", "Path" }) do
			if type(args[key]) == "string" and args[key] ~= "" then
				return args[key]
			end
		end
	end

	--- Lines of text, each with `sign` in front.
	local function signed(text, sign, out)
		text = tostring(text or ""):gsub("\n$", "")
		if text ~= "" then
			for line in P.each_line(text .. "\n") do
				out[#out + 1] = sign .. line
			end
		end
		return out
	end

	--- The hunks of an edit, from what its arguments hold: whole new content,
	--- or replacements of one piece of text by another. agy doesn't log line
	--- numbers, so each hunk starts at line 1.
	function R.edit_hunks(args)
		if type(args.CodeContent) == "string" then
			local lines = signed(args.CodeContent, "+", {})
			return { { oldStart = 0, oldLines = 0, newStart = 1, newLines = #lines, lines = lines } }, true
		end
		local chunks = type(args.ReplacementChunks) == "table" and args.ReplacementChunks or { args }
		local hunks = {}
		for _, c in ipairs(chunks) do
			if type(c) == "table" and (c.TargetContent or c.ReplacementContent) then
				local lines = signed(c.ReplacementContent, "+", signed(c.TargetContent, "-", {}))
				local removed = 0
				for _, l in ipairs(lines) do
					removed = removed + (l:sub(1, 1) == "-" and 1 or 0)
				end
				hunks[#hunks + 1] = { oldStart = 1, oldLines = removed, newStart = 1, newLines = #lines - removed, lines = lines }
			end
		end
		return hunks, false
	end

	--- The turn has ended: the model replied without a tool call, or asked a
	--- question.
	local function turn_ended(state)
		local at = P.epoch(state.at)
		if state.turn.at and at and not state.turn.ms then
			state.turn.ms = math.max(0, at - state.turn.at) * 1000
			state.claude_ms = state.claude_ms + state.turn.ms
		end
	end

	local function tool_call(state, call, n)
		local name = tostring(call.name or "")
		local args = type(call.args) == "table" and call.args or {}
		local id = state.seq .. ":" .. n
		state.tools[id] = { name = name, input = args }
		state.agy_pending = state.agy_pending or {}
		state.agy_pending[#state.agy_pending + 1] = { id = id, name = name, args = args }
		local lower = name:lower()
		if name == "ask_question" then
			local questions = {}
			for _, q in ipairs(type(args.questions) == "table" and args.questions or {}) do
				questions[#questions + 1] = { question = type(q) == "table" and q.question or tostring(q) }
			end
			state.tools[id] = { name = "AskUserQuestion", input = { questions = questions } }
			state.waiting[id] = true
		elseif lower:find("write", 1, true) or lower:find("replace", 1, true) or lower:find("edit", 1, true)
			or lower:find("create", 1, true) then
			local path = edit_path(args)
			if path then
				local hunks, created = R.edit_hunks(args)
				P.add_hunks(state, path, hunks, created)
				state.turn.edits = state.turn.edits + 1
				P.log(state, "main", (created and "Write" or "Edit") .. " → " .. P.short_path(path, state.root))
			end
		end
	end

	--- A tool's result: a command's exit code counts it as a test run or a
	--- failure.
	local function tool_result(state, r)
		local pending = state.agy_pending or {}
		local call = table.remove(pending, 1)
		if not call then
			return
		end
		if call.name == "run_command" then
			local content = tostring(r.content or "")
			local code = tonumber(content:match("exited with code (%-?%d+)"))
			if code then
				local failed = code ~= 0
				if failed then
					state.turn.errors = state.turn.errors + 1
				end
				local output = content:match("[Oo]utput:%s*(.-)%s*$") or content
				P.command_ran(state, tostring(call.args.CommandLine or ""), failed, "exit " .. code .. ": " .. output)
			end
		elseif r.status and r.status ~= "DONE" then
			state.turn.errors = state.turn.errors + 1
		end
	end

	--- Adds one transcript step to the state.
	function R.record(state, r)
		state.seq = state.seq + 1
		state.at = r.created_at or state.at
		if r.type == "USER_INPUT" then
			-- An answer ends the questions asked before it.
			state.waiting = {}
			state.agy_pending = {}
			P.add_prompt(state, R.prompt_text(r.content))
		elseif r.type == "PLANNER_RESPONSE" then
			state.requests = state.requests + 1
			state.model = r.model or state.model
			local context = (tonumber(r.input_tokens) or 0) + (tonumber(r.cache_read_tokens) or 0)
			if context > 0 then
				state.context = context
			end
			if type(r.content) == "string" and r.content:match("%S") then
				P.reply(state, r.content)
			end
			local calls = type(r.tool_calls) == "table" and r.tool_calls or {}
			for n, call in ipairs(calls) do
				if type(call) == "table" then
					tool_call(state, call, n)
				end
			end
			if #calls == 0 or (#calls == 1 and calls[1].name == "ask_question") then
				turn_ended(state)
			end
		elseif r.type == "GENERIC" then
			tool_result(state, r)
		end
	end

	--- No line is skipped: each tool result is paired with its call by order.
	function R.skip()
		return false
	end

	function R.agent_record() end

	--- The final reply in each of the last n turns, newest first, from
	--- transcript lines in file order.
	function R.turns(lines, n)
		local turns, current = {}, nil
		for i = #lines, 1, -1 do
			local line = lines[i]
			local reply = line:find('"PLANNER_RESPONSE"', 1, true) and line:find('"content"', 1, true)
			local prompt = line:find('"USER_INPUT"', 1, true)
			if reply or prompt then
				local ok, r = pcall(rex.json.decode, line)
				if ok and type(r) == "table" then
					if r.type == "PLANNER_RESPONSE" and not current and type(r.content) == "string" and r.content:match("%S") then
						current = r.content
					elseif r.type == "USER_INPUT" then
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
		end
		if current and #turns < n then
			turns[#turns + 1] = current
		end
		return turns
	end

	return R
end
