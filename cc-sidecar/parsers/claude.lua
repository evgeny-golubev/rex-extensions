-- Reads a Claude Code transcript into the panel's state. `P` is panel.lua's
-- module, whose helpers (add_prompt, reply, add_hunks, command_ran, log, …)
-- write the state every parser shares.
return function(P)
	local R = { id = "claude" }

	--- A prompt's text as the panel lists it: a slash command with its
	--- arguments; nil for text Claude Code adds itself.
	function R.prompt_text(text)
		text = text:gsub("^%s+", ""):gsub("%s+$", "")
		local command = text:match("<command%-name>(.-)</command%-name>")
		if command then
			local args = text:match("<command%-args>(.-)</command%-args>") or ""
			return (command .. " " .. args):gsub("%s+$", "")
		elseif text == "" or text:sub(1, 1) == "<" or text:match("^%[Request interrupted") then
			return nil
		end
		return text
	end

	local function add_prompt(state, text)
		text = R.prompt_text(text)
		if text then
			P.add_prompt(state, text)
		end
	end

	--- Ends the background tasks a notification says have finished.
	function R.task_notice(state, text)
		for body in tostring(text):gmatch("<task%-notification>(.-)</task%-notification>") do
			local id = body:match("<task%-id>%s*(.-)%s*</task%-id>")
			local status = body:match("<status>%s*(%w+)%s*</status>")
			if id and status and status ~= "running" then
				state.tasks_bg[id] = nil
			end
		end
	end

	local function result_text(item)
		local c = item.content
		if type(c) == "table" then
			local parts = {}
			for _, p in ipairs(c) do
				if type(p) == "table" and p.text then
					parts[#parts + 1] = p.text
				end
			end
			c = table.concat(parts, "\n")
		end
		return tostring(c or "")
	end

	--- The hunks Claude Code recorded for an edit. A new file records its
	--- content instead.
	local function edit_hunks(extra)
		local hunks = type(extra.structuredPatch) == "table" and extra.structuredPatch or {}
		if #hunks == 0 and extra.type == "create" and type(extra.content) == "string" then
			local lines = {}
			local content = extra.content:gsub("\n$", "") .. "\n"
			for line in content:gmatch("([^\n]*)\n") do
				lines[#lines + 1] = "+" .. line
			end
			hunks = { { oldStart = 0, oldLines = 0, newStart = 1, newLines = #lines, lines = lines } }
		end
		return hunks
	end

	local function tool_result(state, item, record)
		local tool = state.tools[item.tool_use_id]
		if not tool then
			return
		end
		state.waiting[item.tool_use_id] = nil
		local text = result_text(item)
		local failed = item.is_error == true
		local decision = record.permissionDecision
		local extra = type(record.toolUseResult) == "table" and record.toolUseResult or {}
		local input = tool.input or {}

		if extra.backgroundTaskId or (tool.name == "Monitor" and extra.taskId) then
			P.task_started(state, extra.backgroundTaskId or extra.taskId, tool.name, input, extra)
		end
		if tool.name == "Monitor" and tonumber(extra.timeoutMs) then
			local at = P.epoch(state.at)
			if at then
				local list = state.monitors
				list[#list + 1] = { description = state.monitor_names[item.tool_use_id] or "monitor", at = at, expires = at + extra.timeoutMs / 1000 }
				if #list > 100 then
					table.remove(list, 1)
				end
			end
		end
		if type(decision) == "table" then
			P.gate_check(state.gate, decision, tool.name, input, false)
			if decision.decision == "reject" then
				P.log(state, "gate", "✗ " .. tool.name .. " " .. P.tool_target(tool.name, input))
			end
		end
		if failed then
			state.turn.errors = state.turn.errors + 1
		end
		if (tool.name == "Agent" or tool.name == "Task") and not failed then
			P.log(state, "agent", "done · " .. tostring(input.description or input.subagent_type or "agent"))
		end
		if type(decision) == "table" and decision.decision == "reject" and decision.source == "user_reject" then
			return
		end

		if tool.name == "TaskCreate" and not failed then
			local id = (type(extra.task) == "table" and extra.task.id) or text:match("#(%d+)")
			if id then
				id = tostring(id)
				if not state.tasks[id] then
					state.task_order[#state.task_order + 1] = id
				end
				state.tasks[id] = { text = input.subject or input.description or "task", status = "pending" }
			end
		elseif (tool.name == "Edit" or tool.name == "Write" or tool.name == "NotebookEdit") and not failed then
			local path = input.file_path or input.notebook_path
			if path then
				P.add_hunks(state, path, edit_hunks(extra), extra.type == "create")
				state.turn.edits = state.turn.edits + 1
				P.log(state, "main", tool.name .. " → " .. P.short_path(path, state.root))
			end
		elseif tool.name == "Bash" then
			P.command_ran(state, input.command, failed, (text:gsub("^Exit code (%d+)\n?", "exit %1: ")))
		end
	end

	local function assistant(state, record)
		local message = record.message or {}
		if message.model and message.model ~= "<synthetic>" then
			state.model = message.model
		end
		local u = message.usage
		if type(u) == "table" then
			local context = (u.input_tokens or 0) + (u.cache_read_input_tokens or 0) + (u.cache_creation_input_tokens or 0)
			if context > 0 then
				state.context = context
			end
		end
		for _, item in ipairs(type(message.content) == "table" and message.content or {}) do
			if item.type == "text" and item.text and item.text:match("%S") then
				P.reply(state, item.text)
			elseif item.type == "server_tool_use" and tostring(item.name):lower():match("advisor") then
				state.consults[#state.consults + 1] = { id = item.id, at = P.epoch(state.at) }
				P.log(state, "advisor", "consulted")
			elseif item.tool_use_id and item.type ~= "tool_result" then
				for _, c in ipairs(state.consults) do
					if c.id == item.tool_use_id and not c.done then
						c.done = P.epoch(state.at)
						P.log(state, "advisor", "advice returned")
					end
				end
			elseif item.type == "tool_use" then
				local input = type(item.input) == "table" and item.input or {}
				state.tools[item.id] = { name = item.name, input = input }
				if item.name == "Monitor" then
					state.monitor_names[item.id] = input.description or "monitor"
				end
				if item.name == "Agent" or item.name == "Task" then
					state.turn.agents = state.turn.agents + 1
					P.log(state, "agent", "started · " .. tostring(input.description or input.subagent_type or "agent"))
				end
				if item.name == "AskUserQuestion" or item.name == "ExitPlanMode" then
					state.waiting[item.id] = true
				elseif item.name == "TodoWrite" then
					state.todos = input.todos
				elseif item.name == "TaskUpdate" and input.taskId then
					local task = state.tasks[tostring(input.taskId)]
					if task then
						task.status = input.status or task.status
						task.text = input.subject or task.text
					end
				end
			end
		end
	end

	local function user(state, record)
		if record.isCompactSummary then
			return
		end
		local c = record.message and record.message.content
		if type(c) == "string" then
			if c:find("<task-notification>", 1, true) then
				R.task_notice(state, c)
			end
			if not record.isMeta then
				add_prompt(state, c)
			end
		elseif type(c) == "table" then
			local texts = {}
			for _, item in ipairs(c) do
				if item.type == "tool_result" then
					tool_result(state, item, record)
				elseif item.type == "text" and item.text then
					texts[#texts + 1] = item.text
					if item.text:find("<task-notification>", 1, true) then
						R.task_notice(state, item.text)
					end
				end
			end
			if #texts > 0 and not record.isMeta then
				add_prompt(state, table.concat(texts, "\n"))
			end
		end
	end

	--- Adds one transcript record to the state.
	function R.record(state, r)
		state.seq = state.seq + 1
		if r.isSidechain then
			return
		end
		state.at = r.timestamp or state.at
		state.root = r.cwd or state.root
		if r.gitBranch and r.gitBranch ~= "" then
			state.branch = r.gitBranch
		end
		if r.type == "assistant" then
			state.effort = r.perTurnEffort or r.effort or state.effort
		end
		if r.type == "assistant" then
			assistant(state, r)
		elseif r.type == "user" then
			user(state, r)
		elseif r.type == "permission-mode" then
			state.mode = r.permissionMode or state.mode
		elseif r.type == "ai-title" then
			state.title = r.aiTitle or state.title
		elseif r.type == "attachment" and type(r.attachment) == "table" and r.attachment.type == "queued_command"
			and tostring(r.attachment.prompt or ""):find("<task-notification>", 1, true) then
			R.task_notice(state, r.attachment.prompt)
		elseif r.type == "attachment" and type(r.attachment) == "table" and r.attachment.type == "queued_command" then
			add_prompt(state, tostring(r.attachment.prompt or ""))
		elseif r.type == "system" and r.subtype == "compact_boundary" then
			state.compactions = state.compactions + 1
		elseif r.type == "system" and r.subtype == "turn_duration" then
			state.claude_ms = state.claude_ms + (tonumber(r.durationMs) or 0)
			if state.turn.at and not state.turn.ms then
				state.turn.ms = tonumber(r.durationMs)
			end
		end
	end

	--- Whether to skip a line without decoding it, from its start. API request
	--- and file history records are large and repeat what other records hold;
	--- a main-thread API request counts as a request.
	function R.skip(state, head)
		local typed = head:match('^{"type":"([^"]+)"')
		if typed == "api-request" and head:find('"querySource":"repl_main_thread"', 1, true) then
			state.requests = state.requests + 1
		end
		return typed ~= nil and (typed:match("^api%-request") ~= nil or typed:match("^file%-history") ~= nil)
	end

	--- Adds one record of a subagent's transcript to it; its permission
	--- checks go to `gate`, as a subagent's.
	function R.agent_record(a, r, gate)
		local at = P.epoch(r.timestamp)
		if at then
			a.start = a.start or at
			a.last = at
		end
		local m = type(r.message) == "table" and r.message or {}
		local content = type(m.content) == "table" and m.content or {}
		if r.type == "assistant" then
			a.steps = a.steps + 1
			local u = m.usage
			if type(u) == "table" then
				local context = (u.input_tokens or 0) + (u.cache_read_input_tokens or 0) + (u.cache_creation_input_tokens or 0)
				if context > 0 then
					a.context = context
				end
			end
			for _, item in ipairs(content) do
				if item.type == "tool_use" then
					a.calls[item.id] = { name = item.name, input = item.input }
					P.agent_tool(a, item.name, P.tool_target(item.name, item.input))
				elseif item.type == "text" and item.text and item.text:match("%S") then
					a.answer = item.text
				end
			end
		elseif r.type == "user" and type(r.permissionDecision) == "table" and gate then
			for _, item in ipairs(content) do
				if item.type == "tool_result" then
					local call = a.calls[item.tool_use_id] or {}
					P.gate_check(gate, r.permissionDecision, call.name or "tool", call.input, true)
				end
			end
		end
	end

	--- Claude's final message in each of the last n turns, newest first.
	function R.turns(lines, n)
		return P.mentions.turns(lines, n)
	end

	return R
end
