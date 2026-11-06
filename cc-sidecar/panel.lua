-- Runs in a sidecar pane, with three tabs: what changed, by scope (Changes),
-- how the Claude beside it stands (Info), and a dated record of what was said
-- and decided (Log). The watcher
-- passes the Claude pane's block ID and its directory (the repository root, in
-- one) as `claude=` and `cwd=`. The session is read from Claude Code's own
-- files, so no Claude Code setting is needed. With CC_SIDECAR_TEST set, this
-- file returns its functions instead of running.

local M = {}

local terminal = "com.superlogical.terminal"
local home = os.getenv("HOME") or ""
local dir = debug.getinfo(1, "S").source:match("^@?(.*/)") or "./"
local settings = dofile(dir .. "settings.lua")

M.tabs = { "Info", "Changes", "Log" }

--- The scopes of the Changes tab; only Last Turn works without git. The third
--- is "PR", "Branch", or nil on the default branch.
function M.scopes(git, third)
	if not git then
		return { "Last Turn" }
	end
	return { "Last Turn", "Uncommitted", third }
end

--- The scope shown when the scopes change: Branch and PR stand in for each other.
function M.pick_scope(scopes, scope)
	for _, s in ipairs(scopes) do
		if s == scope then
			return scope
		end
	end
	if (scope == "Branch" or scope == "PR") and scopes[3] then
		return scopes[3]
	end
	return scopes[1]
end

--- An open PR from `gh pr view --json number,baseRefName,state`, or nil. The base
--- becomes a git argument, so one that reads as an option is refused.
function M.pr_info(out)
	local ok, pr = pcall(rex.json.decode, out or "")
	if ok and type(pr) == "table" and pr.state == "OPEN" and type(pr.number) == "number"
		and type(pr.baseRefName) == "string" and pr.baseRefName:match("^[^-%s]%S*$") then
		return { number = math.floor(pr.number), base = pr.baseRefName }
	end
end

local reset, bold, dim = "\27[0m", "\27[1m", "\27[2m"
local red, green, yellow, cyan = "\27[31m", "\27[32m", "\27[33m", "\27[36m"

-- Text ----------------------------------------------------------------------

--- Display width, counting each UTF-8 character as one column.
function M.width(s)
	local _, n = s:gsub("\27%[[%d;?]*%a", ""):gsub("[^\128-\191]", "")
	return n
end

--- Cuts a line, which may hold colour codes, to n columns. Lines can quote
--- terminal output, so anything else that could move the cursor or erase the
--- screen is dropped.
function M.clip(s, n)
	local out, w, i = {}, 0, 1
	while i <= #s do
		local esc = s:match("^\27%[[%d;?]*%a", i)
		if esc then
			if esc:sub(-1) == "m" then
				out[#out + 1] = esc
			end
			i = i + #esc
		elseif s:find("^[%z\1-\31\127]", i) then
			i = i + 1
		else
			if w >= n then
				out[#out + 1] = reset
				break
			end
			local c = s:match("^[\192-\255][\128-\191]*", i) or s:sub(i, i)
			out[#out + 1] = c
			w = w + 1
			i = i + #c
		end
	end
	return table.concat(out)
end

--- Splits plain text after its first n characters.
local function cut(s, n)
	local i, count = 1, 0
	while i <= #s and count < n do
		i = i + #(s:match("^[\192-\255][\128-\191]*", i) or "x")
		count = count + 1
	end
	return s:sub(1, i - 1), s:sub(i)
end

--- Word-wraps text to cols columns. The first line starts with `first`, the
--- rest with `rest`, and each paragraph of the text starts a new line. With
--- max_lines, a longer text is cut short with "…".
function M.wrap(text, cols, first, rest, max_lines)
	local lines, line, used = {}, first, 0
	local room = math.max(1, cols - M.width(first))
	local function next_line()
		lines[#lines + 1] = line
		line, used, room = rest, 0, math.max(1, cols - M.width(rest))
	end
	for paragraph in (text .. "\n"):gmatch("([^\n]*)\n") do
		for word in paragraph:gmatch("%S+") do
			local w = M.width(word)
			if used > 0 and used + 1 + w > room then
				next_line()
			end
			while w > room do
				local head, tail = cut(word, room)
				line = line .. head
				used = room
				next_line()
				word, w = tail, M.width(tail)
			end
			if w > 0 then
				line = line .. (used > 0 and " " or "") .. word
				used = used + (used > 0 and 1 or 0) + w
			end
		end
		if used > 0 then
			next_line()
		end
	end
	if max_lines and #lines > max_lines then
		for i = #lines, max_lines + 1, -1 do
			lines[i] = nil
		end
		lines[max_lines] = lines[max_lines] .. " …"
	end
	return lines
end

local function first_line(s)
	return (tostring(s or ""):match("^%s*([^\n]*)") or ""):gsub("%s+$", "")
end

--- A command's first line, without a leading `cd DIR &&`.
function M.command(cmd)
	return (first_line(cmd):gsub("^cd %S+ && ", ""):gsub("%s+", " "))
end

local function short_path(path, root)
	if root and path:sub(1, #root + 1) == root .. "/" then
		return path:sub(#root + 2)
	elseif home ~= "" and path:sub(1, #home) == home then
		return "~" .. path:sub(#home + 1)
	end
	return path
end

local runners = { pytest = true, jest = true, vitest = true, rspec = true, ctest = true, ["swift-test"] = true }
local tools_with_test = {
	npm = true, pnpm = true, yarn = true, bun = true, deno = true, go = true, cargo = true, swift = true,
	xcodebuild = true, make = true, mix = true, dotnet = true, gradle = true, ["./gradlew"] = true, mvn = true,
}
local script_runners = {
	rex = true, lua = true, node = true, python = true, python3 = true, ruby = true, sh = true, bash = true, zsh = true,
}

--- The part of a command that runs tests, or nil: a test runner, a build
--- tool's `test` command, or a script file whose name says test or spec.
function M.test_command(cmd)
	-- gopher-lua crashes on a call chained to a concatenation in a `for`
	-- header, so the line is a local first.
	local line = tostring(cmd or ""):match("^[^\n]*") .. ";"
	for segment in line:gmatch("([^;&|]+)") do
		local words = {}
		for w in segment:gmatch("%S+") do
			if #words > 0 or not w:match("^%w+=") then
				words[#words + 1] = w
			end
		end
		local tool = words[1] and words[1]:match("[^/]*$")
		local hit = tool and runners[tool]
		for i = 2, #words do
			local w = words[i]:lower()
			if tool and tools_with_test[tool] and w:match("^test") then
				hit = true
			elseif tool and script_runners[tool] and (w:match("test[^/]*%.%a+$") or w:match("spec[^/]*%.%a+$")) then
				hit = true
			end
		end
		if hit then
			return (segment:gsub("^%s+", ""):gsub("%s+$", ""))
		end
	end
end

--- A transcript timestamp, which is in UTC, as local month, day and time.
function M.stamp(iso)
	local y, mo, d, h, mi, s = tostring(iso):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then
		return ""
	end
	y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
	-- Days since 1970 by the civil calendar: os.time would read these as local
	-- time, and the offset to undo that shifts around a clock change.
	y = mo <= 2 and y - 1 or y
	local era = math.floor(y / 400)
	local year = y - era * 400
	local day = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
	local days = era * 146097 + year * 365 + math.floor(year / 4) - math.floor(year / 100) + day - 719468
	return os.date("%m-%d %H:%M", days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s))
end

-- Transcript ----------------------------------------------------------------

function M.new_state()
	return {
		offset = 0,
		partial = "",
		seq = 0,
		prompts = {},
		last_prompt = 0,
		decisions = {},
		responses = {},
		tools = {},
		waiting = {},
		tasks = {},
		task_order = {},
		failures = {},
		tests = {},
		compactions = 0,
		claude_ms = 0,
		turn = { order = {}, files = {} },
	}
end

local function add_prompt(state, text)
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	local command = text:match("<command%-name>(.-)</command%-name>")
	if command then
		local args = text:match("<command%-args>(.-)</command%-args>") or ""
		text = (command .. " " .. args):gsub("%s+$", "")
	elseif text == "" or text:sub(1, 1) == "<" or text:match("^%[Request interrupted") then
		return
	end
	state.turn = { order = {}, files = {} }
	-- A queued prompt is recorded twice, with no reply between the two. The same
	-- words after a reply are a new request.
	local latest = state.prompts[#state.prompts]
	if latest and latest.text == text and not (state.last_text and state.last_text.seq > latest.seq) then
		return
	end
	state.prompts[#state.prompts + 1] = { text = text, seq = state.seq, at = state.at }
	state.last_prompt = state.seq
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

--- Adds an edit to the current turn, with the hunks Claude Code recorded. A new
--- file records its content instead.
local function turn_edit(state, path, extra)
	local turn = state.turn
	local f = turn.files[path]
	if not f then
		f = { hunks = {}, added = 0, removed = 0, created = extra.type == "create" }
		turn.files[path] = f
		turn.order[#turn.order + 1] = path
	end
	local hunks = type(extra.structuredPatch) == "table" and extra.structuredPatch or {}
	if #hunks == 0 and extra.type == "create" and type(extra.content) == "string" then
		local lines = {}
		local content = extra.content:gsub("\n$", "") .. "\n"
		for line in content:gmatch("([^\n]*)\n") do
			lines[#lines + 1] = "+" .. line
		end
		hunks = { { oldStart = 0, oldLines = 0, newStart = 1, newLines = #lines, lines = lines } }
	end
	for _, hunk in ipairs(hunks) do
		f.hunks[#f.hunks + 1] = hunk
		for _, line in ipairs(type(hunk.lines) == "table" and hunk.lines or {}) do
			local sign = tostring(line):sub(1, 1)
			if sign == "+" then
				f.added = f.added + 1
			elseif sign == "-" then
				f.removed = f.removed + 1
			end
		end
	end
end

local function decide(state, decision)
	decision.at = state.at
	state.decisions[#state.decisions + 1] = decision
end

--- What a tool call acted on, for a rejected action.
local function tool_target(tool)
	local input = tool.input or {}
	if input.command then
		return M.command(input.command)
	end
	return input.file_path or input.url or input.description or ""
end

--- What the user typed when rejecting a tool call, if anything.
local function user_said(text)
	local said = text:match("the user said:\n(.*)$")
	return said and said:gsub("%s+$", "") or nil
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

	if decision and decision.decision == "reject" and decision.source == "user_reject" then
		if tool.name == "AskUserQuestion" then
			local q = input.questions and input.questions[1]
			decide(state, { kind = "dismissed", text = q and q.question or "a question" })
		elseif tool.name == "ExitPlanMode" then
			decide(state, { kind = "plan_rejected", text = M.plan_title(input.plan), note = user_said(text) })
		else
			decide(state, {
				kind = "rejected",
				text = tool.name .. ": " .. tool_target(tool),
				note = user_said(text),
			})
		end
		return
	end

	if tool.name == "AskUserQuestion" and extra.answers then
		for _, q in ipairs(input.questions or {}) do
			local note = extra.annotations and extra.annotations[q.question]
			decide(state, {
				kind = "answer",
				text = q.question,
				answer = extra.answers[q.question] or "(no answer)",
				note = type(note) == "table" and note.notes or nil,
			})
		end
	elseif tool.name == "ExitPlanMode" then
		decide(state, {
			kind = failed and "plan_rejected" or "plan_approved",
			text = M.plan_title(input.plan),
			note = failed and user_said(text) or nil,
		})
	elseif tool.name == "TaskCreate" and not failed then
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
			turn_edit(state, path, extra)
		end
	elseif tool.name == "Bash" then
		local cmd = M.command(input.command)
		local test = M.test_command(input.command)
		if test then
			state.tests[#state.tests + 1] = { command = test, ok = not failed }
		end
		if failed then
			local err = text:gsub("^Exit code (%d+)\n?", "exit %1: ")
			state.failures[#state.failures + 1] = { command = cmd, error = first_line(err) }
		end
	end
end

--- A plan's title: its first line, without Markdown heading marks.
function M.plan_title(plan)
	return (first_line(plan):gsub("^#+%s*", ""))
end

--- Claude's latest words in a turn are its response, so each text replaces the
--- one before it until the next prompt. Kept short: a session has many.
local function respond(state, text)
	local entry = { text = (cut(text, 2000)), seq = state.seq, at = state.at }
	local latest = state.responses[#state.responses]
	if latest and latest.seq > state.last_prompt then
		state.responses[#state.responses] = entry
	else
		state.responses[#state.responses + 1] = entry
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
			state.last_text = { text = item.text, seq = state.seq }
			respond(state, item.text)
		elseif item.type == "tool_use" then
			local input = type(item.input) == "table" and item.input or {}
			state.tools[item.id] = { name = item.name, input = input }
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
		local c = record.message and record.message.content
		local text = type(c) == "string" and c or (type(c) == "table" and c[1] and c[1].text) or nil
		if text then
			state.summary = { text = text, at = state.at }
		end
		return
	end
	local c = record.message and record.message.content
	if type(c) == "string" then
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
			end
		end
		if #texts > 0 and not record.isMeta then
			add_prompt(state, table.concat(texts, "\n"))
		end
	end
end

--- Adds one transcript record to the state.
function M.record(state, r)
	state.seq = state.seq + 1
	if r.isSidechain then
		return
	end
	state.at = r.timestamp or state.at
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
	elseif r.type == "ai-title" then
		state.title = r.aiTitle or state.title
	elseif r.type == "attachment" and type(r.attachment) == "table" and r.attachment.type == "queued_command" then
		add_prompt(state, tostring(r.attachment.prompt or ""))
	elseif r.type == "system" and r.subtype == "compact_boundary" then
		state.compactions = state.compactions + 1
	elseif r.type == "system" and r.subtype == "turn_duration" then
		state.claude_ms = state.claude_ms + (tonumber(r.durationMs) or 0)
	end
end

--- Adds the complete lines of a chunk of transcript to the state. API
--- request and file history records are large and repeat what other records
--- hold, so they are skipped without being decoded.
function M.feed(state, chunk)
	local text = state.partial .. chunk
	local pos = 1
	while true do
		local nl = text:find("\n", pos, true)
		if not nl then
			break
		end
		local typed = text:match('^{"type":"([^"]+)"', pos)
		if not (typed and (typed:match("^api%-request") or typed:match("^file%-history"))) then
			local line = text:sub(pos, nl - 1):gsub("\\u001b%[[%d;?]*%a", "")
			local ok, r = pcall(rex.json.decode, line)
			if ok and type(r) == "table" then
				M.record(state, r)
			end
		end
		pos = nl + 1
	end
	state.partial = text:sub(pos)
end

--- Reads what was added to the transcript since the last call.
function M.read_new(state, path)
	local f = io.open(path, "rb")
	if not f then
		return
	end
	local size = f:seek("end")
	if size < state.offset then
		f:close()
		return "reset"
	end
	f:seek("set", state.offset)
	while true do
		local chunk = f:read(1048576)
		if not chunk then
			break
		end
		state.offset = state.offset + #chunk
		M.feed(state, chunk)
	end
	f:close()
end

-- Tabs ----------------------------------------------------------------------

local fold_marks = { [true] = "▸ ", [false] = "▾ " }

--- A tab's lines, which also carry each foldable heading's click and position.
local function new_lines(folded, focus, pages)
	return { folded = folded or {}, focus = focus, pages = pages or {}, actions = {}, sections = {} }
end

local function heading(out, title, count, style)
	if #out > 0 then
		out[#out + 1] = ""
	end
	out[#out + 1] = (style or bold) .. title .. reset .. (count and (dim .. " " .. count .. reset) or "")
end

--- Adds what `body` writes, under a blank row; no row if it writes nothing.
local function under_heading(out, body)
	local before = #out
	out[before + 1] = ""
	body()
	if #out == before + 1 then
		out[before + 1] = nil
	end
end

--- A section with a fold mark on its heading. A folded one doesn't build its
--- lines.
local function section(out, name, icon, count, body)
	local folded = out.folded[name] == true
	heading(out, fold_marks[folded] .. icon .. " " .. name, count, out.focus == name and "\27[7m" or bold)
	out.actions[#out] = { kind = "fold", name = name }
	out.sections[#out.sections + 1] = { name = name, line = #out }
	if not folded then
		under_heading(out, body)
	end
end

--- The date in front of a Log entry; nothing for a record without a time.
local function when(entry)
	local stamp = M.stamp(entry.at)
	return stamp ~= "" and (dim .. stamp .. ": " .. reset) or ""
end

local function add(out, lines)
	for _, l in ipairs(lines) do
		out[#out + 1] = l
	end
end

--- The questions at the end of Claude's last reply, while the user hasn't
--- answered it.
function M.reply_questions(state)
	local last = state.last_text
	if not last or last.seq < state.last_prompt then
		return {}
	end
	local out = {}
	for line in (last.text .. "\n"):gmatch("([^\n]*)\n") do
		local q = line:gsub("^%s*[-*>%d.)]*%s*", ""):gsub("%*%*", ""):gsub("`", "")
		if q:match("%?%s*$") then
			out[#out + 1] = q
		end
	end
	return out
end

--- Sections of a compaction summary that say where work stands. Claude Code
--- writes their headings either as Markdown or as "8. Current Work:".
function M.summary_lines(summary)
	local out, keep = {}, false
	-- Claude Code adds instructions for Claude after the summary itself.
	summary = (summary or ""):gsub("\nIf you need specific details from before compaction.*$", "")
	for line in (summary .. "\n"):gmatch("([^\n]*)\n") do
		local h = line:match("^#+%s*(.-)%s*$") or line:match("^%d+%.%s+(%u[%a%s]*):%s*$")
		if h then
			local l = h:lower()
			keep = l:find("current") or l:find("next") or l:find("pending") or l:find("open") or l:find("remaining")
			if keep then
				out[#out + 1] = { heading = h }
			end
		elseif keep and line:match("%S") then
			out[#out + 1] = { text = line }
		end
	end
	return out
end

local status_marks = { completed = green .. "✓" .. reset, in_progress = yellow .. "▸" .. reset }

local function open_section(out, state, cols)
	local open = {}
	for id in pairs(state.waiting) do
		local tool = state.tools[id]
		if tool.name == "AskUserQuestion" then
			for _, q in ipairs(tool.input.questions or {}) do
				add(open, M.wrap(q.question, cols, yellow .. "? " .. reset, "  "))
			end
		else
			add(open, M.wrap("Plan awaiting approval: " .. M.plan_title(tool.input.plan), cols, yellow .. "? " .. reset, "  "))
		end
	end
	for _, q in ipairs(M.reply_questions(state)) do
		add(open, M.wrap(q, cols, yellow .. "? " .. reset, "  "))
	end
	local tasks = {}
	for _, id in ipairs(state.task_order) do
		tasks[#tasks + 1] = state.tasks[id]
	end
	for _, t in ipairs(state.todos or {}) do
		tasks[#tasks + 1] = { text = t.content or t.subject or "", status = t.status }
	end
	for _, t in ipairs(tasks) do
		if t.status ~= "completed" and t.status ~= "deleted" then
			add(open, M.wrap(t.text, cols, (status_marks[t.status] or "○") .. " ", "  "))
		end
	end
	section(out, "Open", "◇", #open == 0 and "none" or nil, function()
		add(out, open)
	end)
end

local function duration(ms)
	local m = math.floor(ms / 60000)
	if m >= 60 then
		return string.format("%dh %02dm", math.floor(m / 60), m % 60)
	end
	return m .. "m"
end

local function session_section(out, state, cols)
	heading(out, "◆ Session")
	local facts = {
		{ "Title", state.title },
		{ "Branch", state.branch },
		{ "Model", state.model },
		{ "Reasoning", state.effort },
		{ "Context", state.context and (math.floor(state.context / 1000) .. "k tokens") },
		{ "Compacted", state.compactions > 0 and (state.compactions .. "×") or nil },
		{ "Claude time", state.claude_ms > 0 and duration(state.claude_ms) or nil },
	}
	under_heading(out, function()
		for _, f in ipairs(facts) do
			if f[2] then
				add(out, M.wrap(tostring(f[2]), cols, dim .. string.format("%-12s", f[1]) .. reset, string.rep(" ", 12)))
			end
		end
	end)
end

local function tests_section(out, state, cols)
	section(out, "Tests", "▷", #state.tests > 0 and tostring(#state.tests) or "none", function()
		for i = #state.tests, math.max(1, #state.tests - 7), -1 do
			local t = state.tests[i]
			out[#out + 1] = M.clip((t.ok and (green .. "✓ ") or (red .. "✗ ")) .. reset .. t.command, cols)
		end
	end)
end

local function failed_section(out, state, cols)
	section(out, "Failed commands", "✗", #state.failures > 0 and tostring(#state.failures) or "none", function()
		for i = #state.failures, math.max(1, #state.failures - 7), -1 do
			local f = state.failures[i]
			out[#out + 1] = M.clip(red .. "✗ " .. reset .. f.command, cols)
			out[#out + 1] = M.clip("  " .. dim .. f.error .. reset, cols)
		end
	end)
end

local function time_left(seconds)
	local m = math.max(1, math.ceil(seconds / 60))
	if m >= 1440 then
		return string.format("%dd %dh", math.floor(m / 1440), math.floor(m % 1440 / 60))
	elseif m >= 60 then
		return string.format("%dh %dm", math.floor(m / 60), m % 60)
	end
	return m .. "m"
end

--- The 5-hour and 7-day limits, from the status line's saved input. A window
--- that has reset since it was saved counts as unused.
local function usage_section(out, limits, cols, now)
	if type(limits) ~= "table" then
		return
	end
	local shown = false
	for _, w in ipairs({ { "Session (5h)", limits.five_hour }, { "Week (7d)", limits.seven_day } }) do
		local name, limit = w[1], w[2]
		if type(limit) == "table" and limit.used_percentage then
			if not shown then
				heading(out, "▤ Usage")
				out[#out + 1] = ""
				shown = true
			end
			local left = limit.resets_at and limit.resets_at - now or nil
			local used = (left and left <= 0) and 0 or limit.used_percentage
			local percent = math.floor(used + 0.5) .. "%"
			out[#out + 1] = name .. string.rep(" ", math.max(1, cols - M.width(name) - #percent)) .. percent
			local filled = math.max(0, math.min(cols, math.floor(cols * used / 100 + 0.5)))
			local colour = used >= 90 and red or used >= 70 and yellow or green
			out[#out + 1] = colour .. string.rep("━", filled) .. reset .. dim .. string.rep("─", cols - filled) .. reset
			if left and left > 0 then
				out[#out + 1] = dim .. "Resets in " .. time_left(left) .. reset
			end
		end
	end
end

--- Everything on the Info tab, most useful first.
function M.info_lines(state, cols, limits, now, folded, focus)
	local out = new_lines(folded, focus)
	session_section(out, state, cols)
	usage_section(out, limits, cols, now or os.time())
	open_section(out, state, cols)
	tests_section(out, state, cols)
	failed_section(out, state, cols)
	return out
end

-- Log -----------------------------------------------------------------------

local page_size = 3

--- The pager at the end of a section, with the columns each side takes.
--- Entries run newest first, so Next, to the left, is the later entries.
function M.pager(page, pages, name)
	local later, position, earlier = "← Next", " " .. page .. "/" .. pages .. " ", "Previous →"
	local ranges = {}
	if page > 1 then
		ranges[#ranges + 1] = { from = 1, to = M.width(later), action = { kind = "page", name = name, page = page - 1 } }
	end
	if page < pages then
		local from = M.width(later) + M.width(position) + 1
		ranges[#ranges + 1] = { from = from, to = from + M.width(earlier) - 1, action = { kind = "page", name = name, page = page + 1 } }
	end
	local function side(text, on)
		return (on and cyan or dim) .. text .. reset
	end
	return side(later, page > 1) .. position .. side(earlier, page < pages), ranges
end

local function summary_section(out, state, cols)
	local summary = state.summary
	local stamp = summary and M.stamp(summary.at) or ""
	section(out, "Summary", "≡", not summary and "none" or (stamp ~= "" and "from " .. stamp or nil), function()
		if not summary then
			return
		end
		local parts = M.summary_lines(summary.text)
		if #parts == 0 then
			out[#out + 1] = dim .. "No current state in this summary." .. reset
		end
		for _, s in ipairs(parts) do
			if s.heading then
				out[#out + 1] = dim .. s.heading .. reset
			else
				add(out, M.wrap(s.text:gsub("^%s+", ""), cols, "  ", "    "))
			end
		end
	end)
end

local function decision_lines(out, d, cols)
	if d.kind == "answer" then
		add(out, M.wrap(d.text, cols, green .. "✓ " .. reset .. when(d) .. dim, "  " .. dim))
		out[#out] = out[#out] .. reset
		add(out, M.wrap(d.answer, cols, "  → ", "    "))
	elseif d.kind == "plan_approved" then
		add(out, M.wrap("Plan approved: " .. d.text, cols, green .. "✓ " .. reset .. when(d), "  "))
	elseif d.kind == "plan_rejected" then
		add(out, M.wrap("Plan rejected: " .. d.text, cols, red .. "✗ " .. reset .. when(d), "  "))
	elseif d.kind == "dismissed" then
		add(out, M.wrap("Question dismissed: " .. d.text, cols, red .. "✗ " .. reset .. when(d), "  "))
	else
		add(out, M.wrap("Rejected " .. d.text, cols, red .. "✗ " .. reset .. when(d), "  ", 3))
	end
	if d.note and d.note ~= "" then
		add(out, M.wrap(d.note, cols, "  " .. cyan .. "“", "   ", 4))
		out[#out] = out[#out] .. "”" .. reset
	end
end

--- A section that lists its entries newest first, a page at a time.
local function log_section(out, name, icon, entries, draw)
	local pages = math.max(1, math.ceil(#entries / page_size))
	local page = math.max(1, math.min(pages, out.pages[name] or 1))
	section(out, name, icon, #entries == 0 and "none" or tostring(#entries), function()
		local newest = #entries - (page - 1) * page_size
		for i = newest, math.max(1, newest - page_size + 1), -1 do
			draw(entries[i])
		end
		if pages > 1 then
			local line, ranges = M.pager(page, pages, name)
			out[#out + 1] = ""
			out[#out + 1] = line
			out.actions[#out] = { ranges = ranges }
		end
	end)
	out.sections[#out.sections].page, out.sections[#out.sections].pages = page, pages
end

--- Everything on the Log tab.
function M.log_lines(state, cols, folded, focus, pages)
	local out = new_lines(folded, focus, pages)
	summary_section(out, state, cols)
	log_section(out, "Decisions", "◈", state.decisions, function(d)
		decision_lines(out, d, cols)
	end)
	log_section(out, "Requests", "›", state.prompts, function(p)
		add(out, M.wrap(p.text, cols, cyan .. "› " .. reset .. when(p), "  ", 6))
	end)
	log_section(out, "Responses", "‹", state.responses, function(r)
		add(out, M.wrap(r.text:gsub("%*%*", ""):gsub("`", ""), cols, cyan .. "‹ " .. reset .. when(r), "  ", 8))
	end)
	return out
end

-- Changes -------------------------------------------------------------------

--- `git diff --numstat -z`, as added and removed line totals. A rename's two
--- paths are fields of their own, without the tabs a count has.
function M.numstat(out)
	local added, removed = 0, 0
	for field in out:gmatch("[^%z]+") do
		local a, r = field:match("^(%S+)\t(%S+)\t")
		added = added + (tonumber(a) or 0)
		removed = removed + (tonumber(r) or 0)
	end
	return added, removed
end

--- A scope's rows from `git status`: grouped as Staged and Unstaged, and merged
--- into one list for the tree, where a file is listed once.
function M.uncommitted(files)
	local staged, unstaged, merged = {}, {}, {}
	for _, f in ipairs(files) do
		if f.x == "?" then
			local row = { path = f.path, mark = "A", diff = "untracked" }
			unstaged[#unstaged + 1] = row
			merged[#merged + 1] = row
		else
			if f.x ~= " " then
				staged[#staged + 1] = { path = f.path, mark = f.x, diff = "staged" }
			end
			if f.y ~= " " then
				unstaged[#unstaged + 1] = { path = f.path, mark = f.y, diff = "unstaged" }
			end
			merged[#merged + 1] = { path = f.path, mark = f.y ~= " " and f.y or f.x, diff = "head" }
		end
	end
	local groups = {}
	if #staged > 0 then
		groups[#groups + 1] = { title = "Staged", rows = staged }
	end
	if #unstaged > 0 then
		groups[#groups + 1] = { title = "Unstaged", rows = unstaged }
	end
	return { groups = groups, merged = merged, note = "No uncommitted changes." }
end

--- The Branch scope from `git diff --name-status -z`. Untracked files aren't in
--- that diff, so they're added from the status.
function M.branch_rows(out, files)
	local fields = {}
	for field in out:gmatch("[^%z]+") do
		fields[#fields + 1] = field
	end
	local rows = {}
	local i = 1
	while i < #fields do
		local mark = fields[i]:sub(1, 1)
		-- A rename or copy names the path it came from, then the new one.
		if mark == "R" or mark == "C" then
			i = i + 1
		end
		rows[#rows + 1] = { path = fields[i + 1], mark = mark, diff = "base" }
		i = i + 2
	end
	for _, f in ipairs(files) do
		if f.x == "?" then
			rows[#rows + 1] = { path = f.path, mark = "A", diff = "untracked" }
		end
	end
	table.sort(rows, function(a, b)
		return a.path < b.path
	end)
	return rows
end

--- The Last Turn scope, from the hunks in the transcript.
function M.turn_data(state, root)
	local rows, added, removed = {}, 0, 0
	for _, path in ipairs(state.turn.order) do
		local f = state.turn.files[path]
		rows[#rows + 1] = { path = short_path(path, root), mark = f.created and "A" or "M", diff = "patch", absolute = path }
		added, removed = added + f.added, removed + f.removed
	end
	return {
		groups = #rows > 0 and { { title = "Changed", rows = rows } } or {},
		added = added,
		removed = removed,
		note = "No edits since your last prompt.",
	}
end

--- A file's hunks from this turn, as the text of a patch that names it `shown`.
function M.turn_patch(state, path, shown)
	-- Without the first line, delta takes a/ and b/ for two names, as a rename.
	local out = { "diff --git a/" .. shown .. " b/" .. shown, "--- a/" .. shown, "+++ b/" .. shown }
	for _, hunk in ipairs(state.turn.files[path].hunks) do
		out[#out + 1] = string.format("@@ -%d,%d +%d,%d @@", hunk.oldStart or 0, hunk.oldLines or 0, hunk.newStart or 0, hunk.newLines or 0)
		for _, line in ipairs(type(hunk.lines) == "table" and hunk.lines or {}) do
			out[#out + 1] = tostring(line)
		end
	end
	return table.concat(out, "\n") .. "\n"
end

--- The `git` arguments that show a row's diff.
function M.diff_args(row, base, head)
	local path = row.path
	if row.diff == "staged" or (row.diff == "head" and not head) then
		return { "diff", "--cached", "--", path }
	elseif row.diff == "unstaged" then
		return { "diff", "--", path }
	elseif row.diff == "head" then
		return { "diff", "HEAD", "--", path }
	elseif row.diff == "base" then
		return { "diff", base, "--", path }
	end
	return { "diff", "--no-index", "--", "/dev/null", path }
end

local scope_short = { ["Last Turn"] = "Turn", Uncommitted = "Local" }

--- The scope row, with short names when the full ones don't fit, and the columns
--- each scope takes.
function M.scope_bar(scopes, active, cols)
	local function build(short)
		local parts, ranges, column = {}, {}, 1
		for _, scope in ipairs(scopes) do
			local label = " " .. (short and scope_short[scope] or scope) .. " "
			parts[#parts + 1] = scope == active and ("\27[7m" .. label .. reset) or (dim .. label .. reset)
			ranges[#ranges + 1] = { from = column, to = column + M.width(label) - 1, action = { kind = "scope", scope = scope } }
			column = column + M.width(label) + 1
		end
		return table.concat(parts, " "), ranges, column - 2
	end
	local bar, ranges, used = build(false)
	if used > cols then
		bar, ranges = build(true)
	end
	return bar, ranges
end

local mark_colours = { A = green, D = red, R = cyan, C = cyan, U = red }

local function coloured_mark(mark)
	return (mark_colours[mark] or yellow) .. bold .. mark .. reset
end

local function list_rows(out, built, group, selected, key_prefix)
	for _, row in ipairs(group.rows) do
		local key = key_prefix .. "\0" .. row.path
		local name = row.path:match("[^/]+$") or row.path
		local folder = row.path:match("^(.*)/[^/]*$")
		local chosen = key == selected
		out[#out + 1] = (chosen and (cyan .. "› " .. reset) or "  ")
			.. coloured_mark(row.mark) .. " " .. name
			.. (folder and (dim .. "  " .. folder .. reset) or "")
		built.actions[#out] = { kind = "open", key = key, row = row }
		built.rows[#built.rows + 1] = { key = key, row = row, line = #out }
	end
end

--- Rows as a folder tree. A folder is a row of its own that folds, and hides
--- what's under it.
local function tree_rows(out, built, rows, selected, cols, folded)
	local sorted = {}
	for _, row in ipairs(rows) do
		sorted[#sorted + 1] = row
	end
	local function folders_of(row)
		local parts, paths, path = {}, {}, nil
		for part in row.path:gmatch("[^/]+") do
			parts[#parts + 1] = part
			path = path and (path .. "/" .. part) or part
			paths[#paths + 1] = path
		end
		return parts, paths
	end
	-- Folders before files at each level, each by name.
	table.sort(sorted, function(a, b)
		local left, right = folders_of(a), folders_of(b)
		for i = 1, math.min(#left, #right) do
			if left[i] ~= right[i] then
				local left_dir, right_dir = i < #left, i < #right
				if left_dir ~= right_dir then
					return left_dir
				end
				return left[i] < right[i]
			end
		end
		return #left < #right
	end)
	local counts = {}
	for _, row in ipairs(sorted) do
		local _, paths = folders_of(row)
		for depth = 1, #paths - 1 do
			counts[paths[depth]] = (counts[paths[depth]] or 0) + 1
		end
	end
	local function mark_for(key)
		return key == selected and (cyan .. "› " .. reset) or "  "
	end
	local open = {}
	for _, row in ipairs(sorted) do
		local parts, paths = folders_of(row)
		local hidden = false
		for depth = 1, #parts - 1 do
			local path = paths[depth]
			if open[depth] ~= parts[depth] then
				open[depth] = parts[depth]
				for deeper = depth + 1, #open do
					open[deeper] = nil
				end
				if not hidden then
					local closed = folded[path] == true
					local key = "\0dir\0" .. path
					out[#out + 1] = mark_for(key) .. string.rep("  ", depth - 1) .. dim
						.. fold_marks[closed] .. parts[depth] .. (closed and (" (" .. counts[path] .. ")") or "") .. reset
					built.actions[#out] = { kind = "dir", key = key, path = path }
					built.rows[#built.rows + 1] = { key = key, dir = path, line = #out }
				end
			end
			hidden = hidden or folded[path] == true
		end
		for deeper = #parts, #open do
			open[deeper] = nil
		end
		if not hidden then
			local key = "\0" .. row.path
			local indent = mark_for(key) .. string.rep("  ", #parts - 1)
			local room = math.max(1, cols - M.width(indent) - 2)
			local name = M.clip(parts[#parts] or row.path, room)
			out[#out + 1] = indent .. name .. string.rep(" ", room - M.width(name) + 1) .. coloured_mark(row.mark)
			built.actions[#out] = { kind = "open", key = key, row = row }
			built.rows[#built.rows + 1] = { key = key, row = row, line = #out }
		end
	end
end

--- The Changes tab. `pinned` stays in place above the rows, and `hits` holds
--- the columns of its clickable parts, by pinned line. `actions` is by row line.
function M.changes_view(v, cols)
	local data = v.data
	local built = { lines = {}, pinned = {}, hits = {}, actions = {}, rows = {} }

	local stats = ""
	if (data.added or 0) > 0 or (data.removed or 0) > 0 then
		stats = green .. "+" .. data.added .. reset .. " " .. red .. "−" .. data.removed .. reset .. "  "
	end
	local tree_mark = "≣"
	local right = M.width(stats) + M.width(tree_mark)
	local title = M.clip(v.title or "", math.max(1, cols - right - 1))
	built.pinned[1] = bold .. title .. reset
		.. string.rep(" ", math.max(1, cols - M.width(title) - right))
		.. stats .. (v.tree and (cyan .. tree_mark .. reset) or (dim .. tree_mark .. reset))
	built.hits[1] = { { from = cols - 1, to = cols, action = { kind = "tree" } } }
	built.pinned[2] = ""
	built.pinned[3], built.hits[3] = M.scope_bar(v.scopes, v.scope, cols)
	built.pinned[4] = v.notice and (red .. v.notice .. reset) or ""

	local out = built.lines
	if data.problem then
		add(out, M.wrap(data.problem, cols, dim, dim))
		return built
	end
	local groups = data.groups
	if v.tree and data.merged and #data.merged > 0 then
		groups = { { title = "Changed", rows = data.merged } }
	end
	if #groups == 0 then
		add(out, M.wrap(data.note, cols, dim, dim))
	end
	for _, group in ipairs(groups) do
		local count = group.title .. " (" .. #group.rows .. ")"
		local vs = data.vs and ("vs " .. data.vs) or ""
		if #out > 0 then
			out[#out + 1] = ""
		end
		out[#out + 1] = bold .. count .. reset
			.. (vs ~= "" and (string.rep(" ", math.max(1, cols - M.width(count) - M.width(vs))) .. dim .. vs .. reset) or "")
		if v.tree then
			tree_rows(out, built, group.rows, v.selected, cols, v.folded or {})
		else
			list_rows(out, built, group, v.selected, group.title)
		end
	end
	return built
end



--- The tab bar, with where the shown lines are when they don't all fit, and the
--- columns each tab takes.
function M.tab_bar(tabs, active, cols, position, badges)
	local parts, ranges, column = {}, {}, 1
	for _, name in ipairs(tabs) do
		local badge = badges and badges[name]
		local label = " " .. name .. " " .. (badge and (badge .. " ") or "")
		parts[#parts + 1] = (name == active and ("\27[7m" .. label .. reset) or (dim .. label .. reset))
		ranges[#ranges + 1] = { from = column, to = column + M.width(label) - 1, action = { kind = "tab", tab = name } }
		column = column + M.width(label) + 1
	end
	local bar = table.concat(parts, " ")
	local hint = position or ""
	if hint ~= "" and M.width(bar) + M.width(hint) + 2 <= cols then
		bar = bar .. string.rep(" ", cols - M.width(bar) - M.width(hint)) .. dim .. hint .. reset
	end
	return M.clip(bar, cols), ranges
end

--- The rows left for a tab's lines, under the tab bar, its blank row and any
--- pinned lines.
function M.page(rows, pinned)
	return math.max(1, rows - 2 - (pinned or 0))
end

--- The whole screen: the tab bar, a blank row, any pinned lines, then the tab's
--- lines from `scroll` on. Also returns the tab bar's columns.
--- Lines stop a column short of the edge, where erasing the rest of a full
--- line would also erase its last character.
function M.frame(tabs, active, lines, scroll, cols, rows, opts)
	opts = opts or {}
	cols = cols - 1
	local pinned = opts.pinned or {}
	local page = M.page(rows, #pinned)
	local last = math.min(#lines, scroll + page)
	local position = #lines > page and string.format("%d–%d of %d", scroll + 1, last, #lines) or nil
	local bar, ranges = M.tab_bar(tabs, active, cols, position, opts.badges)
	local out = { bar, "" }
	for _, line in ipairs(pinned) do
		out[#out + 1] = M.clip(line, cols)
	end
	for i = scroll + 1, last do
		out[#out + 1] = M.clip(lines[i], cols)
	end
	return "\27[H" .. table.concat(out, "\27[K\r\n") .. "\27[K\27[J", ranges
end

--- What a click at a 1-based column and row does, or nil. `layout` has the tab
--- bar's columns (`tabs`), and from the tab's view `hits`, `pinned` (a count),
--- `actions` and `scroll`.
function M.hit(layout, x, y)
	local function in_ranges(ranges)
		for _, r in ipairs(ranges or {}) do
			if x >= r.from and x <= r.to then
				return r.action
			end
		end
	end
	if y == 1 then
		return in_ranges(layout.tabs)
	elseif y == 2 then
		return nil
	elseif y <= 2 + layout.pinned then
		return in_ranges(layout.hits[y - 2])
	end
	local action = layout.actions[y - 2 - layout.pinned + layout.scroll]
	if action and action.ranges then
		return in_ranges(action.ranges)
	end
	return action
end

--- The window that holds a block, from a session view.
function M.window_of(view, block_id)
	for _, w in ipairs(view.windows or {}) do
		for _, l in ipairs(w.layers or {}) do
			for _, b in ipairs(l.blocks or {}) do
				if b.block_id == block_id then
					return w
				end
			end
		end
	end
end

function M.float_closed(view, block_id)
	return M.window_of(view, block_id) == nil
end

--- Whether a block's tab is the one in front.
function M.is_active(view, block_id)
	local window = M.window_of(view, block_id)
	return window ~= nil and window.window_id == view.active_window_id
end

local diff_label = "Diff: "

--- The floats an earlier diff left in a window.
function M.old_diffs(window)
	local found = {}
	for _, l in ipairs(window.layers or {}) do
		if l.kind ~= "tiled" then
			for _, b in ipairs(l.blocks or {}) do
				if (b.label or ""):sub(1, #diff_label) == diff_label then
					found[#found + 1] = l.layer_id
					break
				end
			end
		end
	end
	return found
end

-- Gathering -----------------------------------------------------------------

local function exec(argv)
	local ok, r = pcall(rex.exec, argv, { timeout = 5 })
	return ok and r or nil
end

local function read_json(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	local ok, value = pcall(rex.json.decode, text)
	return ok and value or nil
end

local function is_claude(p)
	return p ~= nil and p.argv0 ~= nil and p.argv0:match("[^/]*$") == "claude"
end

function M.claude_pid(process)
	if not process then
		return nil
	end
	if is_claude(process.foreground) then
		return process.foreground.pid
	end
	for _, p in ipairs(process.ancestors or {}) do
		if is_claude(p) then
			return p.pid
		end
	end
end

--- Claude Code keeps a project's transcripts in a folder named after its
--- directory, with every character but letters and digits made a dash.
function M.project_dir(cwd)
	return (cwd:gsub("[^%w]", "-"))
end

local found = {}

--- The transcript and current directory of the Claude with this process ID,
--- from the session file Claude Code writes for each running Claude. /cd
--- changes the directory there, and moves the transcript with it.
function M.transcript(pid)
	local dirs = { os.getenv("CLAUDE_CONFIG_DIR"), home .. "/.claude" }
	for _, dir in pairs(dirs) do
		local s = read_json(dir .. "/sessions/" .. pid .. ".json")
		if s and s.sessionId then
			local path = s.cwd and (dir .. "/projects/" .. M.project_dir(s.cwd) .. "/" .. s.sessionId .. ".jsonl")
			local f = path and io.open(path, "rb")
			if f then
				f:close()
				return path, s.cwd
			end
			if found[s.sessionId] == nil then
				local r = exec({ "/usr/bin/find", dir .. "/projects", "-maxdepth", "2", "-name", s.sessionId .. ".jsonl" })
				found[s.sessionId] = r and r.ok and r.stdout:match("[^\n]+") or false
			end
			return found[s.sessionId] or nil, s.cwd
		end
	end
end

local panel = {
	session_id = os.getenv("REX_SESSION"),
	block_id = os.getenv("REX_BLOCK"),
	claude = rex.args and rex.args.claude,
	root = rex.args and rex.args.cwd or os.getenv("PWD"),
	tab = "Info",
	--- Tab name -> the first line shown.
	scroll = {},
	cols = 80,
	rows = 24,
	git = false,
	files = {},
	head = true,
	scope = "Uncommitted",
	tree = settings.tree(dir),
	--- Section name -> true when folded, shared by all panes through settings.
	folded = settings.folded(dir),
	--- Folder path -> true when folded in this repository's tree.
	folded_dirs = {},
	--- Tab name -> the highlighted section's name.
	focus = {},
	--- Log section name -> the page shown.
	pages = {},
	--- Scope -> the key of the selected row.
	selected = {},
	--- The tab's last built view; cleared by anything that changes it.
	cache = nil,
	state = M.new_state(),
}

local function git(...)
	local r = exec({ "git", "-C", panel.root, ... })
	return r and r.ok and r.stdout or ""
end

--- `git status --porcelain -b -z`: the branch, whether it has a commit yet, and
--- the changed files.
function M.status(out)
	local result = { files = {}, head = true }
	local fields = {}
	for field in out:gmatch("[^%z]+") do
		fields[#fields + 1] = field
	end
	local i = 1
	while i <= #fields do
		local f = fields[i]
		local branch = f:match("^## (.*)")
		if branch then
			result.head = not branch:match("^No commits yet")
			result.branch = branch:match("^No commits yet on (.*)$") or branch:match("^(.-)%.%.%.") or branch
		else
			local x, y, path = f:sub(1, 1), f:sub(2, 2), f:sub(4)
			-- A rename or copy is followed by the path it came from.
			if x == "R" or x == "C" then
				i = i + 1
			end
			result.files[#result.files + 1] = { x = x, y = y, path = path }
		end
		i = i + 1
	end
	return result
end

--- Moves the pane to the repository of the directory Claude works in.
local function follow(cwd)
	if not cwd or cwd == panel.cwd then
		return
	end
	panel.cwd = cwd
	local r = exec({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
	local root = r and r.ok and (r.stdout:gsub("%s+$", "")) or cwd
	if root ~= panel.root then
		panel.root = root
		panel.scroll.Changes = 0
			panel.selected = {}
		rex.call("session.set_block_label", {
			session_id = panel.session_id,
			block_id = panel.block_id,
			label = "Sidecar: " .. (root:match("[^/]+$") or root),
		})
	end
end

--- The ref the Branch scope compares with: where origin/HEAD points, or else
--- main or master.
local function base_ref()
	local remote = git("symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"):gsub("%s+$", "")
	if remote ~= "" then
		return remote
	end
	for _, name in ipairs({ "main", "master" }) do
		if git("rev-parse", "--verify", "--quiet", name) ~= "" then
			return name
		end
	end
end

--- The open PR of the branch, from GitHub through `gh`. It's looked up again on
--- opening Changes, on a new branch or repository, and after 5 minutes; not on
--- every redraw, because the pane takes no keys while it runs.
local pr_cache, pr_ttl = nil, 300
local function pr_lookup()
	local branch = panel.branch
	if not branch or branch:match("^HEAD") then
		return nil
	end
	local key, now = panel.root .. "\0" .. branch, os.time()
	local hit = pr_cache
	if hit and hit.key == key and now - hit.at < pr_ttl then
		return hit.pr
	end
	local r = exec({ "/bin/sh", "-c", 'export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"; cd "$1" && exec gh pr view --json number,baseRefName,state', "sh", panel.root })
	local pr = r and r.ok and M.pr_info(r.stdout) or nil
	pr_cache = { key = key, at = now, pr = pr }
	return pr
end

--- The third scope of the Changes tab, with the PR or the ref it compares with.
local function third_scope()
	if not panel.git then
		return nil
	end
	local pr = pr_lookup()
	if pr then
		local remote = "origin/" .. pr.base
		return "PR", pr, git("rev-parse", "--verify", "--quiet", remote) ~= "" and remote or pr.base
	end
	local ref = base_ref()
	if ref and panel.branch == (ref:gsub("^origin/", "")) then
		return nil
	end
	return "Branch", nil, ref
end

--- Lines in the untracked files, for the totals. git counts them only one call
--- per file, so this reads them, and leaves out big ones and long lists.
local function untracked_lines(files, root)
	local total, read = 0, 0
	for _, file in ipairs(files) do
		if file.x == "?" and read < 50 then
			read = read + 1
			local f = io.open(root .. "/" .. file.path, "rb")
			if f then
				local size = f:seek("end")
				if size and size <= 1048576 then
					f:seek("set", 0)
					local text = f:read("*a") or ""
					local _, n = text:gsub("\n", "")
					total = total + n
				end
				f:close()
			end
		end
	end
	return total
end

--- Loads the scope on show; only that one, as the pane takes no keys while git
--- runs.
local function load_scope()
	local third, pr, ref = third_scope()
	panel.third = third
	panel.scope = M.pick_scope(M.scopes(panel.git, third), panel.scope)
	local data
	if panel.scope == "Last Turn" then
		data = M.turn_data(panel.state, panel.root)
		if not panel.state.path then
			data.problem = "No Claude session found for this pane."
		end
	elseif panel.scope == "Uncommitted" then
		data = M.uncommitted(panel.files)
		data.added, data.removed = M.numstat(git("diff", "--numstat", "-z", panel.head and "HEAD" or "--cached"))
		data.added = data.added + untracked_lines(panel.files, panel.root)
	else
		local base = ref and git("merge-base", "HEAD", ref):gsub("%s+$", "") or ""
		if base == "" then
			data = { groups = {}, problem = pr and ("No " .. pr.base .. " branch to compare with.") or "No main or master branch to compare with." }
		else
			local rows = M.branch_rows(git("diff", "--name-status", "-z", base), panel.files)
			local vs = pr and (pr.base .. " · #" .. pr.number) or (ref:gsub("^origin/", ""))
			data = { groups = #rows > 0 and { { title = "Changed", rows = rows } } or {}, note = "No changes on this branch.", vs = vs }
			data.base = base
			data.added, data.removed = M.numstat(git("diff", "--numstat", "-z", base))
			data.added = data.added + untracked_lines(panel.files, panel.root)
		end
	end
	panel.data = data
end

--- The status line's saved input for a transcript's session, if it saves it.
local function read_limits(path)
	local config, session = path:match("^(.*)/projects/.*/([^/]+)%.jsonl$")
	local saved = config and read_json(config .. "/state/statusline/" .. session .. ".json")
	return saved and saved.rate_limits or nil
end

local function gather()
	local size = rex.block.call(terminal, "size", { session_id = panel.session_id, block_id = panel.block_id })
	if size and size.columns then
		panel.cols, panel.rows = size.columns, size.rows
	end

	local process = panel.claude
		and rex.block.call(terminal, "process", { session_id = panel.session_id, block_id = panel.claude })
	local pid = M.claude_pid(process)
	local path, cwd
	if pid then
		path, cwd = M.transcript(pid)
	end
	follow(cwd)

	panel.folded = settings.folded(dir)
	panel.folded_dirs = settings.folded_dirs(dir, panel.root)

	-- One status call: git status runs slowly in big repositories, and the
	-- pane takes no keys while it runs.
	local r = exec({ "git", "-C", panel.root, "status", "--porcelain", "-b", "-z", "--untracked-files=all" })
	panel.git = r and r.ok or false
	panel.files, panel.branch, panel.head = {}, nil, true
	if panel.git then
		local status = M.status(r.stdout)
		panel.files, panel.branch, panel.head = status.files, status.branch, status.head
	end

	if path then
		if path ~= panel.state.path then
			panel.state = M.new_state()
			panel.state.path = path
		end
		if M.read_new(panel.state, path) == "reset" then
			panel.state = M.new_state()
			panel.state.path = path
			M.read_new(panel.state, path)
		end
		panel.limits = read_limits(path)
	end

	if panel.tab == "Changes" or not panel.data then
		load_scope()
	end
end

local function build(tab)
	if tab == "Changes" then
		return M.changes_view({
			title = panel.branch or (panel.root:match("[^/]+$") or panel.root),
			scope = panel.scope,
			scopes = M.scopes(panel.git, panel.third),
			tree = panel.tree,
			folded = panel.folded_dirs,
			selected = panel.selected[panel.scope],
			data = panel.data or { groups = {}, note = "" },
			notice = panel.notice,
		}, panel.cols - 1)
	end
	local lines
	if not panel.state.path then
		lines = { dim .. "No Claude session found for this pane." .. reset }
	elseif tab == "Log" then
		lines = M.log_lines(panel.state, panel.cols - 1, panel.folded, panel.focus.Log, panel.pages)
	else
		lines = M.info_lines(panel.state, panel.cols - 1, panel.limits, nil, panel.folded, panel.focus.Info)
	end
	return { lines = lines, pinned = {}, hits = {}, actions = lines.actions or {}, sections = lines.sections or {}, rows = {} }
end

--- The tab's view, built again only after something cleared it.
local function current()
	local c = panel.cache
	if not (c and c.tab == panel.tab and c.cols == panel.cols) then
		c = build(panel.tab)
		c.tab, c.cols = panel.tab, panel.cols
		panel.cache = c
	end
	return c
end

local function draw()
	local c = current()
	local page = M.page(panel.rows, #c.pinned)
	local s = panel.scroll[panel.tab] or 0
	if panel.reveal then
		panel.reveal = false
		for _, r in ipairs(c.rows) do
			if r.key == panel.selected[panel.scope] then
				s = math.max(r.line - page, math.min(s, r.line - 1))
			end
		end
	end
	s = math.max(0, math.min(s, #c.lines - page))
	panel.scroll[panel.tab] = s
	local count = #panel.files > 0 and tostring(#panel.files) or nil
	local frame, ranges = M.frame(M.tabs, panel.tab, c.lines, s, panel.cols, panel.rows, { pinned = c.pinned, badges = { Changes = count } })
	panel.layout = { tabs = ranges, hits = c.hits, pinned = #c.pinned, actions = c.actions, scroll = s }
	io.write(frame)
	if io.stdout.flush then
		io.stdout:flush()
	end
end

local function scroll_by(n)
	panel.scroll[panel.tab] = math.max(0, (panel.scroll[panel.tab] or 0) + n)
end

local function set_tab(tab)
	panel.tab = tab
	panel.cache = nil
	if tab == "Changes" then
		pr_cache = nil
		load_scope()
	end
end

local function switch(step)
	for i, name in ipairs(M.tabs) do
		if name == panel.tab then
			set_tab(M.tabs[(i - 1 + step) % #M.tabs + 1])
			return
		end
	end
end

local function set_scope(scope)
	panel.scope = scope
	panel.scroll.Changes = 0
	panel.notice = nil
	panel.cache = nil
	load_scope()
end

local function next_scope()
	local scopes = M.scopes(panel.git, panel.third)
	for i, scope in ipairs(scopes) do
		if scope == panel.scope then
			set_scope(scopes[i % #scopes + 1])
			return
		end
	end
end

local function toggle_tree()
	panel.tree = not panel.tree
	panel.cache = nil
	pcall(settings.set_tree, dir, panel.tree)
end

local function toggle_fold(name)
	local on = not panel.folded[name]
	panel.folded[name] = on or nil
	panel.cache = nil
	pcall(settings.set_folded, dir, name, on)
end

--- Highlights the next or previous section heading and scrolls it into view.
local function next_section(step)
	local sections = current().sections or {}
	local at = 0
	for i, s in ipairs(sections) do
		if s.name == panel.focus[panel.tab] then
			at = i
		end
	end
	local target = sections[math.max(1, math.min(#sections, at + step))]
	if not target then
		return
	end
	panel.focus[panel.tab] = target.name
	local top = panel.scroll[panel.tab] or 0
	if target.line <= top or target.line > top + M.page(panel.rows) then
		panel.scroll[panel.tab] = target.line - 1
	end
	panel.cache = nil
end

local function fold_focused()
	for _, s in ipairs(current().sections or {}) do
		if s.name == panel.focus[panel.tab] then
			toggle_fold(s.name)
			return
		end
	end
	next_section(1)
end

--- Turns the highlighted section's page; `[` and `]` match the pager's sides.
local function page_focused(step)
	for _, s in ipairs(current().sections or {}) do
		if s.name == panel.focus[panel.tab] and s.pages then
			panel.pages[s.name] = math.max(1, math.min(s.pages, s.page + step))
			panel.cache = nil
		end
	end
end

--- Opens a row's diff in a float, replacing any earlier one.
local function open_diff(row)
	local attached, err = rex.call("session.attach", { session_id = panel.session_id })
	if err ~= nil then
		return tostring(err)
	end
	local window = M.window_of(attached.view, panel.block_id)
	if not window then
		return "This pane's tab wasn't found."
	end
	for _, id in ipairs(M.old_diffs(window)) do
		rex.call("session.close_layer", { session_id = panel.session_id, layer_id = id })
	end
	local command = { dir .. "diff-view" }
	if row.diff == "patch" then
		local file = os.tmpname()
		local f = io.open(file, "wb")
		if not f then
			return "Can't write the diff to a temporary file."
		end
		f:write(M.turn_patch(panel.state, row.absolute, row.path))
		f:close()
		command[2], command[3] = "patch", file
	else
		command[2], command[3] = "git", panel.root
		for _, arg in ipairs(M.diff_args(row, panel.data.base, panel.head)) do
			command[#command + 1] = arg
		end
	end
	local created, opened = rex.call("session.new_layer", {
		session_id = panel.session_id,
		window_id = window.window_id,
		bounds = { 0.1, 0.075, 0.8, 0.85 },
		focus = true,
		layout = {
			block = {
				flavor = terminal .. ".shell",
				label = diff_label .. (row.path:match("[^/]+$") or row.path),
				options = { command = command, cwd = panel.root },
			},
		},
	})
	if opened ~= nil then
		return tostring(opened)
	end
	panel.float = created and created.block_ids and created.block_ids[1]
	-- This script's client owns the new block, and has no window to size it, so it
	-- stays 80x24 until the mouse moves over it. Rex.app takes over once released.
	-- With no IDs, this call would release every block in the session.
	if panel.float then
		rex.call("session.disown_block", { session_id = panel.session_id, block_ids = { panel.float } })
	end
end

--- Rex focuses whichever pane it picks when a float closes, so the pane takes
--- focus back. It doesn't if the user has moved to another tab, as focusing
--- would bring this one back to the front.
local function watch_float()
	local result = rex.call("session.view", { session_id = panel.session_id })
	local view = result and (result.view or result)
	if view and M.float_closed(view, panel.float) then
		panel.float = nil
		if M.is_active(view, panel.block_id) then
			rex.call("session.focus_block", { session_id = panel.session_id, block_id = panel.block_id })
		end
	end
end

local function toggle_dir(key, path)
	local on = not panel.folded_dirs[path]
	panel.folded_dirs[path] = on or nil
	panel.selected[panel.scope] = key
	panel.cache = nil
	pcall(settings.set_folded_dir, dir, panel.root, path, on)
end

local function open_row(key, row)
	panel.selected[panel.scope] = key
	panel.notice = open_diff(row)
	panel.cache = nil
end

local function act(action)
	if action.kind == "tab" then
		set_tab(action.tab)
	elseif action.kind == "scope" then
		set_scope(action.scope)
	elseif action.kind == "tree" then
		toggle_tree()
	elseif action.kind == "open" then
		open_row(action.key, action.row)
	elseif action.kind == "fold" then
		toggle_fold(action.name)
	elseif action.kind == "dir" then
		toggle_dir(action.key, action.path)
	elseif action.kind == "page" then
		panel.pages[action.name] = action.page
		panel.cache = nil
	end
end

--- Moves the selection, in the tab that has one, or scrolls.
local function move(step)
	local rows = current().rows
	if #rows == 0 then
		scroll_by(step)
		return
	end
	local at = 0
	for i, r in ipairs(rows) do
		if r.key == panel.selected[panel.scope] then
			at = i
		end
	end
	local target = rows[math.max(1, math.min(#rows, at + step))]
	panel.selected[panel.scope] = target.key
	panel.reveal = true
	panel.cache = nil
end

local function open_selected()
	local rows = current().rows
	for _, r in ipairs(rows) do
		if r.key == panel.selected[panel.scope] then
			if r.dir then
				toggle_dir(r.key, r.dir)
			else
				open_row(r.key, r.row)
			end
			return
		end
	end
	for _, r in ipairs(rows) do
		if r.row then
			open_row(r.key, r.row)
			return
		end
	end
end

--- Reads the rest of an escape sequence that started with ESC, as a key name
--- (arrows and page keys) or, for the mouse, a table.
local function escape()
	local intro = io.read(1)
	if intro ~= "[" and intro ~= "O" then
		return nil
	end
	local body = ""
	while #body < 32 do
		local c = io.read(1)
		if not c then
			return nil
		end
		body = body .. c
		if c:match("[@-~]") then
			break
		end
	end
	local button, x, y, kind = body:match("^<(%d+);(%d+);(%d+)([Mm])$")
	if button then
		return { button = tonumber(button), x = tonumber(x), y = tonumber(y), press = kind == "M" }
	end
	return ({ A = "up", B = "down", C = "right", D = "left", ["5~"] = "pageup", ["6~"] = "pagedown" })[body]
end

--- SGR mouse report: bit 64 marks the wheel, and the low two bits the button.
local function mouse(m)
	local button = m.button % 4
	if m.button >= 64 and m.button < 128 then
		scroll_by(button == 0 and -3 or 3)
	elseif m.press and m.button < 32 and button == 0 and panel.layout then
		local action = M.hit(panel.layout, m.x, m.y)
		if action then
			act(action)
		end
	end
end

local function key(k)
	if k == "\27" then
		k = escape()
	end
	if type(k) == "table" then
		mouse(k)
		return
	end
	local page = M.page(panel.rows, #current().pinned) - 1
	local n = tonumber(k)
	if n and M.tabs[n] then
		set_tab(M.tabs[n])
	elseif k == "\t" or k == "right" then
		switch(1)
	elseif k == "left" then
		switch(-1)
	elseif k == "j" or k == "down" then
		move(1)
	elseif k == "k" or k == "up" then
		move(-1)
	elseif k == " " or k == "pagedown" then
		scroll_by(page)
	elseif k == "b" or k == "pageup" then
		scroll_by(-page)
	elseif k == "g" then
		panel.scroll[panel.tab] = 0
	elseif panel.tab == "Changes" and k == "s" then
		next_scope()
	elseif panel.tab == "Changes" and k == "t" then
		toggle_tree()
	elseif panel.tab == "Changes" and (k == "\n" or k == "\r") then
		open_selected()
	elseif panel.tab ~= "Changes" and k == "n" then
		next_section(1)
	elseif panel.tab ~= "Changes" and k == "p" then
		next_section(-1)
	elseif panel.tab ~= "Changes" and (k == "\n" or k == "\r") then
		fold_focused()
	elseif panel.tab ~= "Changes" and k == "[" then
		page_focused(-1)
	elseif panel.tab ~= "Changes" and k == "]" then
		page_focused(1)
	end
end

if CC_SIDECAR_TEST then
	return M
end

-- Keys arrive one at a time, and a read gives up after a tenth of a second,
-- so the loop redraws without waiting for a key. Modes 1000 and 1006 report
-- clicks and the wheel. A trackpad sends dozens of reports a second, so input
-- is drawn at most every 50 ms and once it stops, and the refresh waits for a
-- second without keys. os.clock is wall time in this runtime.
exec({ "/bin/sh", "-c", "stty -icanon -echo min 0 time 1 </dev/tty" })
io.write("\27[?1049h\27[?1000h\27[?1006h\27[?25l\27[2J")
local gathered, drawn, dirty, typed, watched = 0, 0, false, 0, 0
while true do
	local now = os.clock()
	if panel.float and now - watched >= 0.25 then
		watched = now
		pcall(watch_float)
	end
	if now - gathered >= 2 and now - typed >= 1 then
		gathered = now
		local ok, err = pcall(gather)
		panel.notice = (not ok) and tostring(err) or panel.notice
		panel.cache = nil
		dirty = true
	end
	local k = io.read(1)
	if k then
		local ok, err = pcall(key, k)
		if not ok then
			panel.notice = tostring(err)
			panel.cache = nil
		end
		dirty, typed = true, os.clock()
	end
	if dirty and (not k or os.clock() - drawn >= 0.05) then
		dirty, drawn = false, os.clock()
		local ok, err = pcall(draw)
		if not ok then
			io.write("\27[H\27[2J" .. tostring(err))
		end
	end
end
