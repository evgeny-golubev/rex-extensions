-- Runs in a changes pane, with tabs: what the Claude beside it did
-- (Activity); what was asked, decided and left open in its session
-- (Context); and, in a git repository, the uncommitted changes (Diff). The
-- watcher passes the Claude pane's block ID and its directory (the
-- repository root, in one) as `claude=` and `cwd=`. The session is read from Claude Code's own files, so
-- no Claude Code setting is needed. With CC_PANE_TEST set, this file
-- returns its functions instead of running.

local M = {}

local terminal = "com.superlogical.terminal"
local home = os.getenv("HOME") or ""

--- The tabs, in order; Diff only in a git repository.
function M.tabs(git)
	return git and { "Activity", "Context", "Diff" } or { "Activity", "Context" }
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

--- Cuts plain text to n columns from the left, so a path keeps its file name.
function M.clip_left(s, n)
	local w = M.width(s)
	if w <= n then
		return s
	end
	local _, tail = cut(s, w - n + 1)
	return "…" .. tail
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

-- Transcript ----------------------------------------------------------------

function M.new_state()
	return {
		offset = 0,
		partial = "",
		seq = 0,
		prompts = {},
		seen_prompts = {},
		last_prompt = 0,
		decisions = {},
		tools = {},
		waiting = {},
		tasks = {},
		task_order = {},
		files = {},
		file_order = {},
		failures = {},
		tests = {},
		compactions = 0,
		claude_ms = 0,
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
	if state.seen_prompts[text] then
		return
	end
	state.seen_prompts[text] = true
	state.prompts[#state.prompts + 1] = { text = text, seq = state.seq }
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
			state.decisions[#state.decisions + 1] = { kind = "dismissed", text = q and q.question or "a question" }
		elseif tool.name == "ExitPlanMode" then
			state.decisions[#state.decisions + 1] = { kind = "plan_rejected", text = M.plan_title(input.plan), note = user_said(text) }
		else
			state.decisions[#state.decisions + 1] = {
				kind = "rejected",
				text = tool.name .. ": " .. tool_target(tool),
				note = user_said(text),
			}
		end
		return
	end

	if tool.name == "AskUserQuestion" and extra.answers then
		for _, q in ipairs(input.questions or {}) do
			local note = extra.annotations and extra.annotations[q.question]
			state.decisions[#state.decisions + 1] = {
				kind = "answer",
				text = q.question,
				answer = extra.answers[q.question] or "(no answer)",
				note = type(note) == "table" and note.notes or nil,
			}
		end
	elseif tool.name == "ExitPlanMode" then
		state.decisions[#state.decisions + 1] = {
			kind = failed and "plan_rejected" or "plan_approved",
			text = M.plan_title(input.plan),
			note = failed and user_said(text) or nil,
		}
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
			local f = state.files[path]
			if not f then
				f = { edits = 0 }
				state.files[path] = f
			end
			f.edits = f.edits + 1
			f.seq = state.seq
			for i, p in ipairs(state.file_order) do
				if p == path then
					table.remove(state.file_order, i)
					break
				end
			end
			state.file_order[#state.file_order + 1] = path
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
		state.summary = type(c) == "string" and c or (type(c) == "table" and c[1] and c[1].text) or nil
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

local function heading(out, title, count)
	if #out > 0 then
		out[#out + 1] = ""
	end
	out[#out + 1] = bold .. title .. reset .. (count and (dim .. " " .. count .. reset) or "")
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

--- Sections of the latest compaction summary that say where work stands.
function M.summary_lines(summary)
	local out, keep = {}, false
	-- Claude Code adds instructions for Claude after the summary itself.
	summary = (summary or ""):gsub("\nIf you need specific details from before compaction.*$", "")
	for line in (summary .. "\n"):gmatch("([^\n]*)\n") do
		local h = line:match("^#+%s*(.-)%s*$")
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

function M.context_lines(state, cols)
	local out = {}

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
	heading(out, "Open", #open == 0 and "none" or nil)
	add(out, open)

	local summary = M.summary_lines(state.summary)
	if #summary > 0 then
		heading(out, "From the last summary")
		for _, s in ipairs(summary) do
			if s.heading then
				out[#out + 1] = dim .. s.heading .. reset
			else
				add(out, M.wrap(s.text:gsub("^%s+", ""), cols, "  ", "    "))
			end
		end
	end

	local decided = {}
	for i = #state.decisions, 1, -1 do
		local d = state.decisions[i]
		if d.kind == "answer" then
			add(decided, M.wrap(d.text, cols, green .. "✓ " .. reset .. dim, "  " .. dim))
			decided[#decided] = decided[#decided] .. reset
			add(decided, M.wrap(d.answer, cols, "  → ", "    "))
		elseif d.kind == "plan_approved" then
			add(decided, M.wrap("Plan approved: " .. d.text, cols, green .. "✓ " .. reset, "  "))
		elseif d.kind == "plan_rejected" then
			add(decided, M.wrap("Plan rejected: " .. d.text, cols, red .. "✗ " .. reset, "  "))
		elseif d.kind == "dismissed" then
			add(decided, M.wrap("Question dismissed: " .. d.text, cols, red .. "✗ " .. reset, "  "))
		else
			add(decided, M.wrap("Rejected " .. d.text, cols, red .. "✗ " .. reset, "  ", 3))
		end
		if d.note and d.note ~= "" then
			add(decided, M.wrap(d.note, cols, "  " .. cyan .. "“", "   ", 4))
			decided[#decided] = decided[#decided] .. "”" .. reset
		end
	end
	heading(out, "Decisions", #state.decisions == 0 and "none" or nil)
	add(out, decided)

	local shown = math.min(#state.prompts, 5)
	heading(out, "Requests", #state.prompts == 0 and "none" or (shown < #state.prompts and ("last " .. shown .. " of " .. #state.prompts)) or tostring(shown))
	for i = #state.prompts, #state.prompts - shown + 1, -1 do
		add(out, M.wrap(state.prompts[i].text, cols, cyan .. "› " .. reset, "  ", 6))
	end

	return out
end

local function duration(ms)
	local m = math.floor(ms / 60000)
	if m >= 60 then
		return string.format("%dh %02dm", math.floor(m / 60), m % 60)
	end
	return m .. "m"
end

function M.activity_lines(state, cols, root, changed)
	local out = {}
	heading(out, "Session")
	local facts = {
		{ "Title", state.title },
		{ "Branch", state.branch },
		{ "Model", state.model },
		{ "Reasoning", state.effort },
		{ "Context", state.context and (math.floor(state.context / 1000) .. "k tokens") },
		{ "Compacted", state.compactions > 0 and (state.compactions .. "×") or nil },
		{ "Claude time", state.claude_ms > 0 and duration(state.claude_ms) or nil },
	}
	for _, f in ipairs(facts) do
		if f[2] then
			add(out, M.wrap(tostring(f[2]), cols, dim .. string.format("%-12s", f[1]) .. reset, string.rep(" ", 12)))
		end
	end

	local inside, outside = {}, 0
	for i = #state.file_order, 1, -1 do
		local path = state.file_order[i]
		if root and path:sub(1, #root + 1) == root .. "/" then
			inside[#inside + 1] = path
		else
			outside = outside + 1
		end
	end
	heading(out, "Files Claude edited", #state.file_order > 0 and tostring(#state.file_order) or "none")
	for _, path in ipairs(inside) do
		local mark = changed[path] and (yellow .. "● " .. reset) or (dim .. "○ " .. reset)
		local edits = state.files[path].edits
		local count = edits > 1 and (" ×" .. edits) or ""
		out[#out + 1] = mark .. M.clip_left(short_path(path, root), cols - 2 - #count) .. dim .. count .. reset
	end
	if outside > 0 then
		out[#out + 1] = dim .. "+ " .. outside .. " outside the repository" .. reset
	end

	heading(out, "Tests", #state.tests > 0 and tostring(#state.tests) or "none")
	for i = #state.tests, math.max(1, #state.tests - 7), -1 do
		local t = state.tests[i]
		out[#out + 1] = M.clip((t.ok and (green .. "✓ ") or (red .. "✗ ")) .. reset .. t.command, cols)
	end

	heading(out, "Failed commands", #state.failures > 0 and tostring(#state.failures) or "none")
	for i = #state.failures, math.max(1, #state.failures - 7), -1 do
		local f = state.failures[i]
		out[#out + 1] = M.clip(red .. "✗ " .. reset .. f.command, cols)
		out[#out + 1] = M.clip("  " .. dim .. f.error .. reset, cols)
	end
	return out
end


--- The tab bar, with where the shown lines are when they don't all fit.
function M.tab_bar(tabs, active, cols, position)
	local parts = {}
	for i, name in ipairs(tabs) do
		local label = " " .. i .. " " .. name .. " "
		parts[#parts + 1] = (name == active and ("\27[7m" .. label .. reset) or (dim .. label .. reset))
	end
	local bar = table.concat(parts, " ")
	local hint = position or ""
	if hint ~= "" and M.width(bar) + M.width(hint) + 2 <= cols then
		bar = bar .. string.rep(" ", cols - M.width(bar) - M.width(hint)) .. dim .. hint .. reset
	end
	return M.clip(bar, cols)
end

--- The rows left for a tab's lines, under the tab bar and its blank row.
function M.page(rows)
	return math.max(1, rows - 2)
end

--- The whole screen: the tab bar, a blank row, then the tab's lines from
--- `scroll` on.
--- Lines stop a column short of the edge, where erasing the rest of a full
--- line would also erase its last character.
function M.frame(tabs, active, lines, scroll, cols, rows)
	cols = cols - 1
	local page = M.page(rows)
	local last = math.min(#lines, scroll + page)
	local position = #lines > page and string.format("%d–%d of %d", scroll + 1, last, #lines) or nil
	local out = { M.tab_bar(tabs, active, cols, position), "" }
	for i = scroll + 1, last do
		out[#out + 1] = M.clip(lines[i], cols)
	end
	return "\27[H" .. table.concat(out, "\27[K\r\n") .. "\27[K\27[J"
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
	tabs = M.tabs(false),
	tab = "Activity",
	--- Tab name -> the first line shown.
	scroll = {},
	cols = 80,
	rows = 24,
	diff = {},
	changed = {},
	--- The last built lines, and the tab and width they were built for;
	--- cleared by each gather.
	cache = nil,
	state = M.new_state(),
}

local function git(...)
	local r = exec({ "git", "-C", panel.root, ... })
	return r and r.ok and r.stdout or ""
end

--- `git status --porcelain -b -z`, as `git status -sb` shows it, with the
--- changed files' paths and whether the branch has a commit yet.
function M.status(out, root)
	local result = { lines = {}, changed = {}, head = true }
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
			local name, rest = branch:match("^(.-)(%.%.%..*)$")
			result.lines[#result.lines + 1] = "## " .. green .. (name or branch) .. reset .. (rest and (red .. rest .. reset) or "")
		else
			local x, y, path = f:sub(1, 1), f:sub(2, 2), f:sub(4)
			local shown = path
			-- A rename or copy is followed by the path it came from.
			if x == "R" or x == "C" then
				i = i + 1
				shown = (fields[i] or "") .. " -> " .. path
			end
			result.changed[root .. "/" .. path] = true
			local mark = x == "?" and (red .. "??" .. reset) or (green .. x .. reset .. red .. y .. reset)
			result.lines[#result.lines + 1] = mark .. " " .. shown
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
		panel.scroll.Diff = 0
		rex.call("session.set_block_label", {
			session_id = panel.session_id,
			block_id = panel.block_id,
			label = "Changes: " .. (root:match("[^/]+$") or root),
		})
	end
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

	-- One status call: git status runs slowly in big repositories, and the
	-- pane takes no keys while it runs.
	local r = exec({ "git", "-C", panel.root, "status", "--porcelain", "-b", "-z", "--untracked-files=all" })
	panel.tabs = M.tabs(r and r.ok)
	panel.diff, panel.changed = {}, {}
	if r and r.ok then
		local status = M.status(r.stdout, panel.root)
		panel.diff, panel.changed = status.lines, status.changed
		local stat = git("--no-pager", "diff", "--color=always", "--stat=" .. (panel.cols - 1), status.head and "HEAD" or "--cached")
		panel.diff[#panel.diff + 1] = ""
		for line in stat:gmatch("([^\n]*)\n") do
			panel.diff[#panel.diff + 1] = line
		end
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
	end
end

local function lines_of(tab)
	if tab == "Diff" then
		return panel.diff
	elseif not panel.state.path then
		return { dim .. "No Claude session found for this pane." .. reset }
	elseif tab == "Context" then
		return M.context_lines(panel.state, panel.cols - 1)
	end
	return M.activity_lines(panel.state, panel.cols - 1, panel.root, panel.changed)
end

local function draw()
	local shown = false
	for _, name in ipairs(panel.tabs) do
		shown = shown or name == panel.tab
	end
	if not shown then
		panel.tab = panel.tabs[1]
	end
	local c = panel.cache
	if not (c and c.tab == panel.tab and c.cols == panel.cols) then
		c = { tab = panel.tab, cols = panel.cols, lines = lines_of(panel.tab) }
		panel.cache = c
	end
	local lines = c.lines
	local s = math.max(0, math.min(panel.scroll[panel.tab] or 0, #lines - M.page(panel.rows)))
	panel.scroll[panel.tab] = s
	io.write(M.frame(panel.tabs, panel.tab, lines, s, panel.cols, panel.rows))
	if io.stdout.flush then
		io.stdout:flush()
	end
end

local function scroll_by(n)
	panel.scroll[panel.tab] = math.max(0, (panel.scroll[panel.tab] or 0) + n)
end

local function switch(step)
	for i, name in ipairs(panel.tabs) do
		if name == panel.tab then
			panel.tab = panel.tabs[(i - 1 + step) % #panel.tabs + 1]
			return
		end
	end
end

--- Reads the rest of an escape sequence that started with ESC, as a key
--- name: arrows and page keys.
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
	return ({ A = "up", B = "down", C = "right", D = "left", ["5~"] = "pageup", ["6~"] = "pagedown" })[body]
end

local function key(k)
	if k == "\27" then
		k = escape()
	end
	local page = M.page(panel.rows) - 1
	local n = tonumber(k)
	if n and panel.tabs[n] then
		panel.tab = panel.tabs[n]
	elseif k == "\t" or k == "right" then
		switch(1)
	elseif k == "left" then
		switch(-1)
	elseif k == "j" or k == "down" then
		scroll_by(1)
	elseif k == "k" or k == "up" then
		scroll_by(-1)
	elseif k == " " or k == "pagedown" then
		scroll_by(page)
	elseif k == "b" or k == "pageup" then
		scroll_by(-page)
	elseif k == "g" then
		panel.scroll[panel.tab] = 0
	end
end

if CC_PANE_TEST then
	return M
end

-- Keys arrive one at a time, and a read gives up after a tenth of a second,
-- so the loop redraws without waiting for a key. The mouse stays the
-- terminal's, so a drag selects text: on the alternate screen, with alternate
-- scroll (mode 1007), the wheel comes as arrow keys. A trackpad sends dozens
-- a second, so input is drawn at most every 50 ms and once it stops, and the
-- refresh waits for a second without keys. os.clock is wall time in this
-- runtime.
exec({ "/bin/sh", "-c", "stty -icanon -echo min 0 time 1 </dev/tty" })
io.write("\27[?1049h\27[?1007h\27[?25l\27[2J")
local gathered, drawn, dirty, typed = 0, 0, false, 0
while true do
	local now = os.clock()
	if now - gathered >= 2 and now - typed >= 1 then
		gathered = now
		local ok, err = pcall(gather)
		if not ok then
			panel.diff = { red .. tostring(err) .. reset }
		end
		panel.cache = nil
		dirty = true
	end
	local k = io.read(1)
	if k then
		key(k)
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
