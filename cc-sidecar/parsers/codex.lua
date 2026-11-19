-- Reads a Codex rollout (~/.codex/sessions/…/rollout-*.jsonl) into the
-- panel's state. Codex logs each finished step as an `item_completed` event
-- with a typed item (UserMessage, AgentMessage, CommandExecution, FileChange,
-- McpToolCall, SubAgentActivity, ContextCompaction), so this reads those and
-- skips the raw model `response_item`s, which repeat them. `P` is panel.lua's
-- module; see parsers/claude.lua.
--
-- Codex doesn't log approval decisions in the rollout, and runs commands
-- under its app-server rather than the TUI, so the Gate box and background
-- tasks stay empty for a Codex pane.
return function(P)
	local R = { id = "codex" }

	--- The text parts of an item's content.
	local function text_of(content)
		local parts = {}
		for _, c in ipairs(type(content) == "table" and content or {}) do
			if type(c) == "table" and type(c.text) == "string" then
				parts[#parts + 1] = c.text
			end
		end
		return table.concat(parts, "\n")
	end

	--- The command a shell runs: the script of `zsh -lc SCRIPT`, or the
	--- arguments joined.
	function R.command_text(command)
		if type(command) == "string" then
			return command
		end
		if type(command) ~= "table" then
			return ""
		end
		local n = #command
		if n >= 3 and tostring(command[n - 1]):match("^%-%a*c$") then
			return tostring(command[n])
		end
		local parts = {}
		for i, part in ipairs(command) do
			parts[i] = tostring(part)
		end
		return table.concat(parts, " ")
	end

	--- Hunks in the panel's shape from a unified diff's text.
	function R.hunks(diff)
		local hunks, hunk = {}, nil
		-- Kept in a local: this runtime crashes iterating gmatch on a
		-- parenthesised call joined with a string.
		local text = tostring(diff or "") .. "\n"
		for line in text:gmatch("([^\n]*)\n") do
			local a, b, c, d = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
			if a then
				hunk = {
					oldStart = tonumber(a),
					oldLines = b ~= "" and tonumber(b) or 1,
					newStart = tonumber(c),
					newLines = d ~= "" and tonumber(d) or 1,
					lines = {},
				}
				hunks[#hunks + 1] = hunk
			elseif hunk and line:match("^[ +-]") then
				hunk.lines[#hunk.lines + 1] = line
			end
		end
		return hunks
	end

	--- A whole file as one hunk of added (or removed) lines.
	local function whole(content, sign)
		local lines = {}
		local text = tostring(content or ""):gsub("\n$", "")
		if text ~= "" then
			for line in (text .. "\n"):gmatch("([^\n]*)\n") do
				lines[#lines + 1] = sign .. line
			end
		end
		if sign == "+" then
			return { { oldStart = 0, oldLines = 0, newStart = 1, newLines = #lines, lines = lines } }
		end
		return { { oldStart = 1, oldLines = #lines, newStart = 0, newLines = 0, lines = lines } }
	end

	local function file_change(state, item)
		if item.status ~= "completed" then
			state.turn.errors = state.turn.errors + 1
			return
		end
		local paths = {}
		for path in pairs(type(item.changes) == "table" and item.changes or {}) do
			paths[#paths + 1] = path
		end
		table.sort(paths)
		for _, path in ipairs(paths) do
			local change = item.changes[path]
			local kind = type(change) == "table" and change.type or "update"
			local shown = type(change) == "table" and type(change.move_path) == "string" and change.move_path or path
			local hunks
			if kind == "add" then
				hunks = whole(change.content, "+")
			elseif kind == "delete" then
				hunks = whole(change.content, "-")
			else
				hunks = R.hunks(change.unified_diff)
			end
			local f = P.add_hunks(state, shown, hunks, kind == "add")
			f.deleted = kind == "delete" or nil
			state.turn.edits = state.turn.edits + 1
			local verb = kind == "add" and "Add" or kind == "delete" and "Delete" or "Edit"
			P.log(state, "main", verb .. " → " .. P.short_path(shown, state.root))
		end
	end

	local function item_completed(state, item)
		local t = item.type
		if t == "UserMessage" then
			P.add_prompt(state, text_of(item.content))
		elseif t == "AgentMessage" then
			local text = text_of(item.content)
			if text:match("%S") then
				P.reply(state, text)
			end
		elseif t == "CommandExecution" then
			-- A command that didn't run, as one declined, is neither a pass
			-- nor a failure.
			if item.status ~= "completed" and item.status ~= "failed" then
				return
			end
			local code = tonumber(item.exit_code)
			local failed = item.status == "failed" or (code or 0) ~= 0
			if failed then
				state.turn.errors = state.turn.errors + 1
			end
			local output = tostring(item.aggregated_output or "")
			local why = output:match("%S") and output or ("status " .. tostring(item.status))
			P.command_ran(state, R.command_text(item.command), failed, (code and ("exit " .. code .. ": ") or "") .. why)
		elseif t == "FileChange" then
			file_change(state, item)
		elseif t == "McpToolCall" then
			if item.status == "failed" then
				state.turn.errors = state.turn.errors + 1
				P.log(state, "main", "✗ " .. tostring(item.server) .. "." .. tostring(item.tool))
			end
		elseif t == "SubAgentActivity" then
			if item.agent_thread_id then
				state.subagent_status = state.subagent_status or {}
				state.subagent_status[item.agent_thread_id] = item.kind
			end
			local name = item.agent_path and (tostring(item.agent_path):gsub("^/root/", "")) or "agent"
			if item.kind == "started" then
				state.turn.agents = state.turn.agents + 1
				P.log(state, "agent", "started · " .. name)
			elseif item.kind == "completed" then
				P.log(state, "agent", "done · " .. name)
			elseif item.kind == "interrupted" then
				P.log(state, "agent", "stopped · " .. name)
			end
		elseif t == "ContextCompaction" then
			state.compactions = state.compactions + 1
		end
	end

	local function token_count(state, p)
		local info = type(p.info) == "table" and p.info or {}
		local last = type(info.last_token_usage) == "table" and info.last_token_usage or {}
		local context = tonumber(last.input_tokens)
		if context and context > 0 then
			state.context = context
		end
		local status = state.status or { limits = {} }
		status.window = tonumber(info.model_context_window) or status.window
		if type(p.rate_limits) == "table" then
			status.limits = P.agents.codex.limits(p.rate_limits)
		end
		state.status = status
	end

	local function turn_ended(state, p)
		local ms = tonumber(p.duration_ms)
		if not ms and tonumber(p.started_at) and tonumber(p.completed_at) then
			ms = (p.completed_at - p.started_at) * 1000
		end
		state.claude_ms = state.claude_ms + (ms or 0)
		state.turn.at = state.turn.at or P.epoch(state.at)
		state.turn.ms = ms or 0
	end

	local function settings(state, s)
		if type(s) ~= "table" then
			return
		end
		state.model = s.model or state.model
		state.effort = s.effort or s.reasoning_effort or state.effort
		local sandbox = type(s.sandbox_policy) == "table" and s.sandbox_policy.type or nil
		local approval = s.approval_policy
		if approval or sandbox then
			state.mode = table.concat({ approval or "", sandbox or "" }, approval and sandbox and " · " or "")
		end
		state.root = s.cwd or state.root
	end

	--- Adds one rollout record to the state.
	function R.record(state, r)
		state.seq = state.seq + 1
		state.at = r.timestamp or state.at
		local p = type(r.payload) == "table" and r.payload or {}
		if r.type == "event_msg" then
			local t = p.type
			if t == "item_completed" and type(p.item) == "table" then
				item_completed(state, p.item)
			elseif t == "token_count" then
				token_count(state, p)
			elseif t == "task_started" then
				-- A turn another agent started has no prompt; it still runs.
				state.turn.at = state.turn.at or P.epoch(state.at)
				state.turn.ms = nil
			elseif t == "task_complete" then
				turn_ended(state, p)
			elseif t == "turn_aborted" then
				turn_ended(state, p)
				P.log(state, "main", "interrupted")
			elseif t == "thread_settings_applied" then
				settings(state, p.thread_settings)
			end
		elseif r.type == "turn_context" then
			settings(state, p)
		elseif r.type == "session_meta" then
			state.root = p.cwd or state.root
			if type(p.git) == "table" and p.git.branch and p.git.branch ~= "" then
				state.branch = p.git.branch
			end
		end
	end

	--- Whether to skip a line without decoding it, from its start. Raw model
	--- items repeat the completed items, reasoning carries no text worth
	--- showing, and world state is large; a usage record counts as a request.
	function R.skip(state, head)
		local typed = head:match('^{"timestamp":"[^"]*","ordinal":%d+,"type":"([^"]+)"') or head:match('"type":"([^"]+)"')
		if typed == "token_usage_record" then
			state.requests = state.requests + 1
			return true
		end
		return typed == "response_item" or typed == "world_state" or typed == "inter_agent_communication_metadata"
			or head:find('"item":{"type":"Reasoning"', 1, true) ~= nil
	end

	--- Adds one record of a subagent's rollout to it.
	function R.agent_record(a, r)
		local at = P.epoch(r.timestamp)
		if at then
			a.start = a.start or at
			a.last = at
		end
		local p = type(r.payload) == "table" and r.payload or {}
		if r.type ~= "event_msg" then
			return
		end
		if p.type == "token_count" then
			local last = type(p.info) == "table" and type(p.info.last_token_usage) == "table" and p.info.last_token_usage or {}
			if tonumber(last.input_tokens) and last.input_tokens > 0 then
				a.context = last.input_tokens
			end
		elseif p.type == "item_completed" and type(p.item) == "table" then
			local item = p.item
			if item.type == "AgentMessage" then
				local text = text_of(item.content)
				if text:match("%S") then
					a.answer = text
				end
			elseif item.type == "CommandExecution" then
				a.steps = a.steps + 1
				P.agent_tool(a, "Shell", P.mask(P.command(R.command_text(item.command))))
			elseif item.type == "FileChange" then
				a.steps = a.steps + 1
				local path = next(type(item.changes) == "table" and item.changes or {})
				P.agent_tool(a, "Edit", path and P.short_path(path, nil) or "")
			elseif item.type == "McpToolCall" then
				a.steps = a.steps + 1
				P.agent_tool(a, tostring(item.server) .. "." .. tostring(item.tool), "")
			end
		end
	end

	--- The final message in each of the last n turns, newest first, from
	--- rollout lines in file order. Only completed user and agent messages are
	--- decoded.
	function R.turns(lines, n)
		local turns, current = {}, nil
		for i = #lines, 1, -1 do
			local line = lines[i]
			if line:find('"item_completed"', 1, true)
				and (line:find('"AgentMessage"', 1, true) or line:find('"UserMessage"', 1, true)) then
				local ok, r = pcall(rex.json.decode, line)
				local item = ok and type(r) == "table" and type(r.payload) == "table" and r.payload.item
				local kind = type(item) == "table" and item.type or nil
				if kind == "AgentMessage" and not current then
					local text = text_of(item.content)
					if text:match("%S") then
						current = text
					end
				elseif kind == "UserMessage" then
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
