-- Reads an Antigravity CLI (agy) transcript,
-- brain/<id>/.system_generated/logs/transcript_full.jsonl, into the panel's
-- state. Each line is a step: USER_INPUT holds the prompt inside
-- <USER_REQUEST>; PLANNER_RESPONSE is a model step with its model, tokens,
-- an optional reply and its tool calls; GENERIC steps are the tool results,
-- in the order of the calls; CHECKPOINT marks a context compaction.
-- `P` is panel.lua's module; see parsers/claude.lua.
return function(P)
	local R = { id = "agy" }

	local EFFORTS = { low = true, medium = true, high = true, xhigh = true, max = true }

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

	--- The hunks of an edit, from what its arguments hold: whole new content
	--- (`CodeContent` or `Content`), or replacements (`TargetContent`/`ReplacementContent`
	--- or `Target`/`Replacement`). agy doesn't log line numbers, so each hunk starts at line 1.
	function R.edit_hunks(args)
		local whole = type(args.CodeContent) == "string" and args.CodeContent
			or (type(args.Content) == "string" and args.Content or nil)
		if whole then
			local lines = signed(whole, "+", {})
			return { { oldStart = 0, oldLines = 0, newStart = 1, newLines = #lines, lines = lines } }, not args.Overwrite and not args.Append
		end
		local chunks = type(args.ReplacementChunks) == "table" and args.ReplacementChunks or { args }
		local hunks = {}
		for _, c in ipairs(chunks) do
			if type(c) == "table" then
				local before = c.TargetContent or c.Target
				local after = c.ReplacementContent or c.Replacement
				if before or after then
					local lines = signed(after, "+", signed(before, "-", {}))
					local removed = 0
					for _, l in ipairs(lines) do
						removed = removed + (l:sub(1, 1) == "-" and 1 or 0)
					end
					hunks[#hunks + 1] = { oldStart = 1, oldLines = removed, newStart = 1, newLines = #lines - removed, lines = lines }
				end
			end
		end
		return hunks, false
	end

	--- Effort suffix embedded in a model ID (e.g. gemini-4-neon-high -> "high").
	local function model_effort(model)
		local suffix = tostring(model or ""):match("%-(%a+)$")
		if suffix and EFFORTS[suffix:lower()] then
			return suffix:lower()
		end
	end

	--- The turn has ended: the model replied without a tool call, or asked a
	--- question.
	local function turn_ended(state)
		local at = P.epoch(state.at)
		if state.turn.at and at then
			local next_ms = math.max(0, at - state.turn.at) * 1000
			local prev_ms = state.turn.ms or 0
			state.turn.ms = next_ms
			if next_ms > prev_ms then
				state.claude_ms = state.claude_ms + (next_ms - prev_ms)
			end
		end
	end

	local function tool_target(name, args)
		if type(args) ~= "table" then
			return ""
		end
		local path = edit_path(args)
		if path then
			return path
		end
		if name == "run_command" then
			return tostring(args.CommandLine or args.toolSummary or "")
		elseif name == "run_workflow" then
			return tostring(args.Description or "")
		elseif name == "invoke_subagent" then
			return tostring(args.Role or args.TypeName or "")
		elseif name == "search_web" then
			return tostring(args.query or "")
		end
		return ""
	end

	local function tool_call(state, call, n)
		local name = tostring(call.name or "")
		local args = type(call.args) == "table" and call.args or {}
		local id = state.seq .. ":" .. n
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
		elseif name == "invoke_subagent" then
			state.turn.agents = state.turn.agents + 1
			local label = tostring(args.Role or args.TypeName or "subagent")
			P.log(state, "agent", "started · " .. label, "agent")
		elseif name == "run_workflow" then
			local desc = tostring(args.Description or "workflow")
			P.log(state, "main", "Workflow → " .. desc)
		elseif name == "read_file" then
			local path = edit_path(args)
			if path then
				P.log(state, "main", "read " .. P.short_path(path, state.root), "explore")
			end
		elseif name == "search_web" and args.query then
			P.log(state, "main", tostring(args.query), "search")
		elseif name == "call_mcp_tool" and args.ToolName then
			P.log(state, "main", P.short_mcp(args.ToolName, args.ServerName), "mcp")
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
	--- failure; backgrounded commands (status == "RUNNING") are not errors.
	local function tool_result(state, r)
		local pending = state.agy_pending or {}
		local call = table.remove(pending, 1)
		if not call then
			return
		end
		local content = tostring(r.content or "")
		local is_error = r.status == "ERROR" or r.status == "FAILED"
		if call.name == "run_command" then
			local matched = content:match("exited with code (%-?%d+)")
			local code = matched and tonumber(matched)
			if code then
				local failed = code ~= 0
				if failed then
					state.turn.errors = state.turn.errors + 1
				end
				local output = content:match("[Oo]utput:%s*(.-)%s*$") or content
				P.command_ran(state, tostring(call.args.CommandLine or ""), failed, "exit " .. code .. ": " .. output)
			elseif is_error then
				state.turn.errors = state.turn.errors + 1
				P.command_ran(state, tostring(call.args.CommandLine or ""), true, content:match("[^\n]+") or "error")
			end
		elseif call.name == "run_workflow" then
			local desc = tostring(call.args.Description or "workflow")
			local script = tostring(call.args.Script or "")
			local is_test = script:find("vitest", 1, true) or script:find("test:unit", 1, true)
				or script:find("test.lua", 1, true) or script:find("pytest", 1, true)
				or script:find("jest", 1, true) or script:find("go test", 1, true) or script:find("cargo test", 1, true)
			if is_error then
				state.turn.errors = state.turn.errors + 1
				local err_line = content:match("RuntimeError:%s*([^\n]+)") or content:match("Error:%s*([^\n]+)") or content:match("[^\n]+") or "workflow failed"
				if is_test then
					state.tests[#state.tests + 1] = { command = desc, ok = false }
				end
				P.command_ran(state, desc, true, err_line)
			elseif r.status == "DONE" and is_test then
				local failed = content:find("FAIL ", 1, true) ~= nil or content:find("exit=1", 1, true) ~= nil
				if failed then
					state.turn.errors = state.turn.errors + 1
				end
				state.tests[#state.tests + 1] = { command = desc, ok = not failed }
				if failed then
					P.command_ran(state, desc, true, "tests failed")
				end
			end
		elseif call.name == "invoke_subagent" then
			local sub_id = content:match('"conversationId"%s*:%s*"([%w%-]+)"')
			local role = tostring(call.args.Role or "")
			if sub_id and role ~= "" then
				state.agy_roles = state.agy_roles or {}
				state.agy_roles[sub_id] = role
			end
			if is_error then
				state.turn.errors = state.turn.errors + 1
			end
		elseif is_error then
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
			state.tools = {}
			state.agy_pending = {}
			P.add_prompt(state, R.prompt_text(r.content))
		elseif r.type == "CHECKPOINT" then
			state.compactions = state.compactions + 1
			P.log(state, "main", "Compacted context")
		elseif r.type == "PLANNER_RESPONSE" then
			state.requests = state.requests + 1
			if r.model then
				state.model = r.model
				local eff = model_effort(r.model)
				if eff then
					state.effort = eff
				end
			end
			local context = (tonumber(r.input_tokens) or 0) + (tonumber(r.cache_read_tokens) or 0)
			if context > 0 then
				state.context = context
			end
			if type(r.content) == "string" and r.content:match("%S") then
				P.reply(state, r.content)
			end
			local calls = type(r.tool_calls) == "table" and r.tool_calls or {}
			if #calls > 0 and not (#calls == 1 and calls[1].name == "ask_question") then
				-- Resuming work in the same turn (e.g. after a background task finishes).
				state.turn.ms = nil
			end
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

	--- Adds one record of a subagent's transcript to it.
	function R.agent_record(a, r)
		local at = P.epoch(r.created_at)
		if at then
			a.start = a.start or at
			a.last = at
		end
		if r.type == "PLANNER_RESPONSE" then
			a.steps = a.steps + 1
			local context = (tonumber(r.input_tokens) or 0) + (tonumber(r.cache_read_tokens) or 0)
			if context > 0 then
				a.context = context
			end
			if type(r.content) == "string" and r.content:match("%S") then
				a.answer = r.content
			end
			for _, call in ipairs(type(r.tool_calls) == "table" and r.tool_calls or {}) do
				if type(call) == "table" and call.name then
					P.agent_tool(a, tostring(call.name), tool_target(tostring(call.name), call.args))
				end
			end
		end
	end

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
