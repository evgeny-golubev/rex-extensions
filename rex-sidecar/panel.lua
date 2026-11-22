-- Runs in a sidecar pane, with three tabs: what changed, by scope (Changes),
-- how the Claude beside it stands (Info), and the files and links Claude's
-- replies mention (Artifacts). The watcher
-- passes the Claude pane's block ID and its directory (the repository root, in
-- one) as `claude=` and `cwd=`. The session is read from Claude Code's own
-- files, so no Claude Code setting is needed. With REX_SIDECAR_TEST set, this
-- file returns its functions instead of running.

local M = {}

local terminal = "com.superlogical.terminal"
local home = os.getenv("HOME") or ""
local dir = debug.getinfo(1, "S").source:match("^@?(.*/)") or "./"
local settings = dofile(dir .. "settings.lua")
local agents = dofile(dir .. "../agents/init.lua")
local mentions = dofile(dir .. "mentions.lua")
local leaf = dofile(dir .. "leaf.lua")
--- The folder of settings.json: a throwaway one in the tests.
local settings_dir = REX_SIDECAR_TEST_BASE or dir
local rex_binary = home
	.. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"

M.tabs = { "Info" }


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

--- Iterates over the lines of text, each ended by "\n". Patterns fail on a
--- line of about a million characters, so the ends are found by plain search.
local function each_line(text)
	local pos = 1
	return function()
		local nl = text:find("\n", pos, true)
		if nl then
			local line = text:sub(pos, nl - 1)
			pos = nl + 1
			return line
		end
	end
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
	for paragraph in each_line(text .. "\n") do
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

local secret_words = { "token", "secret", "password", "passwd", "pwd", "auth", "key", "credential", "cookie" }

local function secret_name(word)
	local lower = word:lower()
	for _, w in ipairs(secret_words) do
		if lower:find(w, 1, true) then
			return true
		end
	end
end

--- A command or path with what looks like a credential replaced by •••: the
--- value of a NAME=, --name or name: whose name says token, key, password and
--- the like, a bearer token, and long runs of key-like characters.
function M.mask(text)
	local out, hide = {}, false
	for space, word in tostring(text or ""):gmatch("(%s*)(%S+)") do
		local masked = word
		if hide then
			masked, hide = "•••", false
		else
			local name, sep = word:match("^([%w_%-%.]+)([=:])")
			if name and secret_name(name) and #word > #name + 1 then
				masked = name .. sep .. "•••"
			elseif word:match("^%-%-?[%w_%-]+$") and secret_name(word) or word == "Bearer" or word:lower() == "-u" then
				hide = true
			elseif word:match("[%w+/=_%-]" .. string.rep("[%w+/=_%-]", 31)) and not word:find("/", 1, true) then
				masked = "•••"
			end
		end
		out[#out + 1] = space .. masked
	end
	return table.concat(out)
end

local utc_offset = os.time() - os.time(os.date("!*t"))

--- Seconds since 1970 from a transcript timestamp, or nil.
function M.epoch(ts)
	local y, mo, d, h, mi, s = tostring(ts or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then
		return nil
	end
	return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) }) + utc_offset
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

--- Adds an event to the session log, which keeps the latest 300. `who` is
--- main, agent, gate or advisor.
function M.log(state, who, text)
	local log = state.log
	log[#log + 1] = { at = M.epoch(state.at), who = who, text = first_line(text) }
	if #log > 300 then
		table.remove(log, 1)
	end
end

--- A background task Claude started: a shell named by its command, as Claude
--- Code's own list names it, credentials masked, or a monitor by its
--- description, which ends at its timeout unless it's persistent.
function M.task_started(state, id, name, input, extra)
	local at = M.epoch(state.at)
	local monitor = name == "Monitor"
	local timeout = tonumber(extra.timeoutMs)
	state.tasks_bg[id] = {
		id = id,
		at = at,
		monitor = monitor,
		name = monitor and (input.description or "monitor") or M.mask(M.command(input.command or "")),
		expires = (monitor and at and timeout and not extra.persistent) and (at + timeout / 1000) or nil,
	}
end

--- The background tasks still running at `now`, newest first. With `live`,
--- the shells M.processes found, a task also needs one that started within 10
--- seconds of it: an end the transcript never got, as when Claude restarted,
--- leaves no shell behind.
function M.running_tasks(state, now, live)
	local out, used = {}, {}
	for _, t in pairs(state.tasks_bg) do
		local alive = not (t.expires and now > t.expires)
		if alive and live then
			alive = false
			for i, p in ipairs(live) do
				if not used[i] and t.at and math.abs(now - t.at - p.age) <= 10 then
					used[i], alive = true, true
					break
				end
			end
		end
		if alive then
			out[#out + 1] = t
		end
	end
	table.sort(out, function(a, b)
		return (a.at or 0) > (b.at or 0)
	end)
	return out
end

--- What one turn did, from the prompt on.
function M.new_turn(at, seq)
	return { order = {}, files = {}, at = at, seq = seq, edits = 0, errors = 0, agents = 0 }
end

--- Permission checks: the latest ones, and totals by verdict and by family.
function M.new_gate()
	return { checks = {}, total = 0, verdicts = { allowed = 0, classifier = 0, you = 0, denied = 0 }, families = { file = 0, shell = 0, other = 0 } }
end

local file_tools = { Read = true, Edit = true, Write = true, MultiEdit = true, NotebookEdit = true, Glob = true, Grep = true }
local shell_tools = { Bash = true, BashOutput = true, KillShell = true, Monitor = true }

--- A permission decision's verdict: denied, allowed by you, by the auto-mode
--- classifier, or by a rule or the mode.
function M.verdict(decision)
	if decision.decision == "reject" then
		return "denied"
	elseif tostring(decision.source or ""):match("^user") then
		return "you"
	elseif decision.reasonType == "classifier" then
		return "classifier"
	end
	return "allowed"
end

--- What a tool call was about, short, with credentials masked.
function M.tool_target(name, input)
	input = type(input) == "table" and input or {}
	local target = input.command and M.command(input.command)
		or input.file_path or input.notebook_path or input.path or input.pattern or input.url or input.description or ""
	return M.mask(tostring(target))
end

--- Adds a permission check to the gate. `sub` is true for a subagent's.
function M.gate_check(gate, decision, name, input, sub)
	local family = file_tools[name] and "file" or shell_tools[name] and "shell" or "other"
	local verdict = M.verdict(decision)
	gate.total = gate.total + 1
	gate.verdicts[verdict] = gate.verdicts[verdict] + 1
	gate.families[family] = gate.families[family] + 1
	gate.checks[#gate.checks + 1] = { verdict = verdict, family = family, tool = name, target = M.tool_target(name, input), sub = sub }
	if #gate.checks > 400 then
		table.remove(gate.checks, 1)
	end
end

--- A transcript's state; `parser` is the adapter ID of its agent, Claude's
--- by default.
function M.new_state(parser)
	return {
		parser = parser,
		offset = 0,
		partial = "",
		seq = 0,
		prompts = {},
		last_prompt = 0,
		responses = {},
		tools = {},
		waiting = {},
		tasks = {},
		task_order = {},
		failures = {},
		tests = {},
		compactions = 0,
		claude_ms = 0,
		requests = 0,
		turn = M.new_turn(),
		gate = M.new_gate(),
		consults = {},
		log = {},
		monitors = {},
		monitor_names = {},
		tasks_bg = {},
	}
end

--- Adds a prompt the person wrote, which starts a new turn. Parsers pass
--- only such text, without what the agent adds itself.
function M.add_prompt(state, text)
	text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then
		return
	end
	state.turn = M.new_turn(M.epoch(state.at), state.seq)
	-- A queued prompt is recorded twice, with no reply between the two. The same
	-- words after a reply are a new request.
	local latest = state.prompts[#state.prompts]
	if latest and latest.text == text and not (state.last_text and state.last_text.seq > latest.seq) then
		return
	end
	state.prompts[#state.prompts + 1] = { text = text, seq = state.seq, at = state.at }
	M.log(state, "main", "› " .. text)
	state.last_prompt = state.seq
end

--- Adds an edit's hunks, in the shape of Claude Code's structuredPatch, to
--- the current turn, and returns the turn's record of the file.
function M.add_hunks(state, path, hunks, created)
	local turn = state.turn
	local f = turn.files[path]
	if not f then
		f = { hunks = {}, added = 0, removed = 0, created = created == true }
		turn.files[path] = f
		turn.order[#turn.order + 1] = path
	end
	for _, hunk in ipairs(hunks or {}) do
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
	return f
end

--- A shell command finished: a test run is recorded, and a failure with the
--- first line of its error.
function M.command_ran(state, command, failed, err)
	local cmd = M.command(command)
	local test = M.test_command(command)
	if test then
		state.tests[#state.tests + 1] = { command = test, ok = not failed }
	end
	if failed then
		state.failures[#state.failures + 1] = { command = cmd, error = first_line(err) }
		M.log(state, "main", "✗ " .. M.mask(cmd))
	end
end

--- A plan's title: its first line, without Markdown heading marks.
function M.plan_title(plan)
	return (first_line(plan):gsub("^#+%s*", ""))
end

--- The agent's latest words in a turn are its response, so each text
--- replaces the one before it until the next prompt.
function M.reply(state, text)
	state.last_text = { text = text, seq = state.seq }
	local entry = { text = text, seq = state.seq }
	local latest = state.responses[#state.responses]
	if latest and latest.seq > state.last_prompt then
		state.responses[#state.responses] = entry
	else
		state.responses[#state.responses + 1] = entry
	end
end

--- Adds a tool call to a subagent's latest three.
function M.agent_tool(a, name, target)
	target = tostring(target or "")
	a.tools[#a.tools + 1] = tostring(name) .. (target ~= "" and (" " .. dim .. target .. reset) or "")
	if #a.tools > 3 then
		table.remove(a.tools, 1)
	end
end

M.mentions = mentions
M.agents = agents
M.first_line, M.short_path, M.each_line = first_line, short_path, each_line

--- A reader for each agent's transcripts, by adapter ID; see parsers/.
local parsers = {}
for _, id in ipairs({ "claude", "codex", "agy", "pi", "opencode" }) do
	parsers[id] = dofile(dir .. "parsers/" .. id .. ".lua")(M)
end
M.parsers = parsers
M.task_notice = parsers.claude.task_notice

--- The parser of a state or subagent: its agent's, or Claude's.
local function parser_of(t)
	return parsers[t.parser] or parsers.claude
end

--- Adds one transcript record to the state.
function M.record(state, r)
	parser_of(state).record(state, r)
end

--- Adds the complete lines of a chunk of transcript to the state. The parser
--- skips large records it doesn't need without decoding them.
function M.feed(state, chunk)
	local parser = parser_of(state)
	local text = state.partial .. chunk
	local pos = 1
	while true do
		local nl = text:find("\n", pos, true)
		if not nl then
			break
		end
		if not parser.skip(state, text:sub(pos, math.min(nl, pos + 400))) then
			local line = text:sub(pos, nl - 1)
			-- A pattern scans a long line slowly, so most lines skip it.
			if line:find("\\u001b", 1, true) then
				line = line:gsub("\\u001b%[[%d;?]*%a", "")
			end
			local ok, r = pcall(rex.json.decode, line)
			if ok and type(r) == "table" then
				parser.record(state, r)
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
		if coroutine.running() then
			coroutine.yield()
		end
	end
	f:close()
end

-- Processes ---------------------------------------------------------------

local carriers = { zsh = true, bash = true, sh = true, sleep = true, env = true, timeout = true, caffeinate = true, tail = true }
-- Claude also starts caffeinate itself, which isn't one of its commands.
local shells = { zsh = true, bash = true, sh = true, fish = true }

--- Seconds from ps's etime: [[dd-]hh:]mm:ss.
function M.etime(text)
	local d, rest = tostring(text or ""):match("^(%d+)%-(.+)$")
	rest = rest or tostring(text or "")
	local seconds = 0
	for n in rest:gmatch("%d+") do
		seconds = seconds * 60 + tonumber(n)
	end
	return seconds + (tonumber(d) or 0) * 86400
end

--- The shells Claude runs right now, from `ps -axo pid=,ppid=,etime=,comm=`,
--- newest first, as rex-crab-pond finds them. A process has only its program's
--- name, never its arguments, which can hold secrets. A shell is a monitor
--- Claude started when one was recorded within 10 seconds of its start and
--- hasn't timed out; otherwise it's named by its program, "monitor" when it
--- runs tail, "waiting" when it only sleeps, or "shell".
function M.processes(claude_pid, ps, monitors, now)
	local children = {}
	for line in tostring(ps or ""):gmatch("[^\n]+") do
		local pid, ppid, etime, comm = line:match("^%s*(%d+)%s+(%d+)%s+(%S+)%s+(.+)$")
		if pid then
			local p = { pid = tonumber(pid), age = M.etime(etime), name = (comm:match("[^/]+$") or comm):gsub("^%-", "") }
			children[tonumber(ppid)] = children[tonumber(ppid)] or {}
			table.insert(children[tonumber(ppid)], p)
		end
	end
	local out, used = {}, {}
	for _, shell in ipairs(children[claude_pid] or {}) do
		if shells[shell.name] then
			local program, tails, sleeps, queue = nil, false, false, { shell.pid }
			while #queue > 0 do
				for _, child in ipairs(children[table.remove(queue, 1)] or {}) do
					if child.name == "tail" then
						tails = true
					elseif child.name == "sleep" then
						sleeps = true
					elseif not program and not carriers[child.name] then
						program = child.name
					end
					queue[#queue + 1] = child.pid
				end
			end
			local best, closest
			for _, m in ipairs(monitors or {}) do
				if not used[m] and now <= m.expires then
					local apart = math.abs(now - m.at - shell.age)
					if apart <= 10 and (not closest or apart < closest) then
						best, closest = m, apart
					end
				end
			end
			local p = { pid = shell.pid, age = shell.age }
			if best then
				used[best] = true
				p.name, p.kind = best.description, "monitor"
			elseif tails then
				p.name, p.kind = "monitor", "watching output"
			elseif program then
				p.name, p.kind = program, "shell"
			elseif sleeps then
				p.name, p.kind = "waiting", "shell"
			else
				p.name, p.kind = "shell", "shell"
			end
			out[#out + 1] = p
		end
	end
	table.sort(out, function(a, b)
		return a.age < b.age
	end)
	return out
end

-- Subagents ----------------------------------------------------------------

function M.new_agent(id, parser)
	return { id = id, parser = parser, offset = 0, partial = "", steps = 0, tools = {}, calls = {} }
end

--- Adds one record of a subagent's transcript to it; its permission checks go
--- to `gate`, as a subagent's.
function M.agent_record(a, r, gate)
	parser_of(a).agent_record(a, r, gate)
end

--- Reads what was added to a subagent's transcript since the last call.
function M.read_agent(a, path, gate)
	local f = io.open(path, "rb")
	if not f then
		return
	end
	f:seek("set", a.offset)
	while true do
		local chunk = f:read(1048576)
		if not chunk then
			break
		end
		a.offset = a.offset + #chunk
		local text = a.partial .. chunk
		local pos = 1
		while true do
			local nl = text:find("\n", pos, true)
			if not nl then
				break
			end
			local ok, r = pcall(rex.json.decode, text:sub(pos, nl - 1))
			if ok and type(r) == "table" then
				M.agent_record(a, r, gate)
			end
			pos = nl + 1
		end
		a.partial = text:sub(pos)
		if coroutine.running() then
			coroutine.yield()
		end
	end
	f:close()
end

-- Tabs ----------------------------------------------------------------------

local fold_marks = { [true] = "▸ ", [false] = "▾ " }

local orange, lavender, mint, purple = "\27[38;5;209m", "\27[38;5;147m", "\27[38;5;114m", "\27[38;5;141m"
local gold, teal, blue, grey = "\27[38;5;221m", "\27[38;5;80m", "\27[38;5;75m", "\27[38;5;245m"
local aqua = "\27[38;5;87m"
M.colours = {
	orange = orange, lavender = lavender, mint = mint, purple = purple, gold = gold, teal = teal, blue = blue, grey = grey, aqua = aqua,
	reset = reset, bold = bold, dim = dim, red = red, green = green, yellow = yellow, cyan = cyan,
}

--- Below this width, sections are plain headings instead of boxes.
M.box_min = 36

--- A tab's lines, which also carry each foldable heading's click and position.
local function new_lines(folded, focus)
	return { folded = folded or {}, focus = focus, actions = {}, sections = {} }
end

local function add(out, lines)
	for _, l in ipairs(lines) do
		out[#out + 1] = l
	end
end

--- A line clipped or padded to n columns.
local function pad(s, n)
	local c = M.clip(s, n)
	return c .. reset .. string.rep(" ", math.max(0, n - M.width(c)))
end

--- A box's top line, or its only line when folded: the title on the left and
--- `right` at the end, joined by the border.
local function box_top(colour, title, right, cols, folded)
	local tail = right ~= "" and (" " .. right .. " ") or ""
	local room = cols - 5 - M.width(tail)
	if room < 4 then
		tail, room = "", cols - 5
	end
	title = M.clip(title, room) .. reset
	local fill = cols - 4 - M.width(title) - M.width(tail)
	local left, close = folded and "╶ " or "╭ ", folded and "╴" or "╮"
	return colour .. left .. reset .. title .. " " .. colour .. string.rep("─", fill) .. reset .. tail .. colour .. close .. reset
end

--- Adds a box: a blank row first, the top line, what `body(inner_cols)` adds,
--- framed, and the bottom line. Clicks stored by line in `actions` keep working,
--- and their column ranges move with the frame. Narrower than M.box_min, the
--- box is a heading with its lines under it. Returns the top line's number.
function M.box(out, actions, cols, colour, title, right, body, folded)
	right = right or ""
	if #out > 0 then
		out[#out + 1] = ""
	end
	if cols < M.box_min then
		out[#out + 1] = title .. reset .. (right ~= "" and (" " .. dim .. right .. reset) or "")
		local head = #out
		if not folded then
			body(cols)
		end
		return head
	end
	out[#out + 1] = box_top(colour, title, right, cols, folded)
	local head = #out
	if folded then
		return head
	end
	local first = #out + 1
	body(cols - 4)
	for i = first, #out do
		out[i] = colour .. "│ " .. reset .. pad(out[i], cols - 4) .. colour .. " │" .. reset
		local a = actions and actions[i]
		for _, r in ipairs(a and a.ranges or {}) do
			r.from, r.to = r.from + 2, r.to + 2
		end
	end
	out[#out + 1] = colour .. "╰" .. string.rep("─", cols - 2) .. "╯" .. reset
	return head
end

--- A box that folds: a click on its top line, or Enter on it after n and p,
--- folds it. opts: colour, title (the name by default), icon, right (shown
--- dim), or status (shown as it is).
local function section(out, cols, name, opts, body)
	local folded = out.folded[name] == true
	local colour = opts.colour or grey
	local title = (opts.icon and (opts.icon .. " ") or "") .. (opts.title or name)
	if folded or cols < M.box_min then
		title = fold_marks[folded] .. title
	end
	title = (out.focus == name and "\27[7m" or bold) .. colour .. title .. reset
	local right = opts.status or ((opts.right or "") ~= "" and (dim .. opts.right .. reset)) or ""
	local head = M.box(out, out.actions, cols, colour, title, right, body, folded)
	out.actions[head] = { kind = "fold", name = name }
	out.sections[#out.sections + 1] = { name = name, line = head }
end

--- Joins parts with two spaces into as few lines of n columns as they fit.
local function flow(out, parts, n)
	local line = ""
	for i = 1, table.maxn(parts) do
		local p = parts[i]
		if p and p ~= "" then
			if line ~= "" and M.width(line) + 2 + M.width(p) > n then
				out[#out + 1] = line
				line = p
			else
				line = line == "" and p or (line .. "  " .. p)
			end
		end
	end
	if line ~= "" then
		out[#out + 1] = line
	end
end

--- A gauge of n cells, `fraction` of them on.
local function cells(fraction, n, colour, on, off)
	local k = math.max(0, math.min(n, math.floor(fraction * n + 0.5)))
	return colour .. string.rep(on or "▰", k) .. reset .. dim .. string.rep(off or "▱", n - k) .. reset
end

local function level_colour(percent)
	return percent >= 90 and red or percent >= 70 and yellow or mint
end

--- "Opus 5.5" from "claude-opus-5-5".
function M.model_name(id)
	local name, major, minor = tostring(id or ""):match("^claude%-(%a+)%-(%d+)%-(%d+)")
	if name then
		return name:sub(1, 1):upper() .. name:sub(2) .. " " .. major .. "." .. minor
	end
	return id
end

function M.tokens(n)
	if n >= 999500 then
		return string.format("%.1fM", n / 1000000)
	elseif n >= 1000 then
		return math.floor(n / 1000 + 0.5) .. "k"
	end
	return tostring(math.floor(n))
end

--- A span as 7s, 2m37s or 1h05m.
function M.span(seconds)
	local s = math.max(0, math.floor(seconds))
	if s < 60 then
		return s .. "s"
	elseif s < 3600 then
		return string.format("%dm%02ds", math.floor(s / 60), s % 60)
	end
	return string.format("%dh%02dm", math.floor(s / 3600), math.floor(s % 3600 / 60))
end

--- A running clock: 0:42, or 1:02:03.
function M.clock(seconds)
	local s = math.max(0, math.floor(seconds))
	if s >= 3600 then
		return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60)
	end
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function spin(now)
	return spinner[math.floor(now) % #spinner + 1]
end

local function time_left(seconds)
	local m = math.max(1, math.ceil(seconds / 60))
	if m >= 1440 then
		return string.format("%dd%dh", math.floor(m / 1440), math.floor(m % 1440 / 60))
	elseif m >= 60 then
		return string.format("%dh%dm", math.floor(m / 60), m % 60)
	end
	return m .. "m"
end

local function duration(ms)
	local m = math.floor(ms / 60000)
	if m >= 60 then
		return string.format("%dh %02dm", math.floor(m / 60), m % 60)
	end
	return m .. "m"
end

--- The questions at the end of Claude's last reply, while the user hasn't
--- answered it.
function M.reply_questions(state)
	local last = state.last_text
	if not last or last.seq < state.last_prompt then
		return {}
	end
	local out = {}
	for line in each_line(last.text .. "\n") do
		local q = line:gsub("^%s*[-*>%d.)]*%s*", ""):gsub("%*%*", ""):gsub("`", "")
		if q:match("%?%s*$") then
			out[#out + 1] = q
		end
	end
	return out
end

local status_marks = { completed = green .. "✓" .. reset, in_progress = yellow .. "▸" .. reset }

--- Whether Claude is working on a prompt.
function M.running(state)
	return state.turn.at ~= nil and state.turn.ms == nil
end

local efforts = { low = 1, medium = 2, high = 3, xhigh = 4, max = 5 }

--- The main box: model, effort, mode and requests; context; limits.
--- `status` is the session's, as agents/init.lua describes, or Claude Code's
--- saved status line input; without one, what the transcript recorded. A
--- limit window that has reset since it was saved counts as unused.
local function main_box(out, state, cols, o)
	local status = type(o.status) == "table" and o.status or nil
	if status and status.limits == nil then
		status = agents.claude.status(status)
	end
	-- The session's own status first; the transcript fills what it lacks.
	local recorded = state.status or {}
	status = status or recorded
	local limits = (status.limits and #status.limits > 0) and status.limits or recorded.limits or {}
	local who = o.agent_name or "Claude"
	local now = o.now
	local running = M.running(state)
	local right = running and (orange .. "● running" .. reset) or (dim .. "○ idle" .. reset)
	section(out, cols, "Main", { colour = orange, title = (M.model_name(state.model) or who) .. " · main", status = right }, function(n)
		local first_line = #out
		local about = {}
		if state.title or o.session_name then
			about[#about + 1] = state.title or o.session_name
		end
		if state.branch then
			about[#about + 1] = dim .. state.branch .. reset
		end
		if #about > 0 then
			out[#out + 1] = table.concat(about, dim .. " · " .. reset)
		end
		local e = efforts[tostring(state.effort or "")]
		flow(out, {
			e and ("effort " .. cells(e / 5, 5, orange, "▮", "▯") .. " " .. bold .. state.effort .. reset),
			state.mode and ("mode " .. state.mode),
			state.requests > 0 and (state.requests .. " req"),
		}, n)
		local window = tonumber(status.window) or tonumber(recorded.window)
		local ctx = state.context
		local parts = {}
		if ctx and window and window > 0 then
			local percent = ctx / window * 100
			parts[#parts + 1] = "ctx " .. cells(percent / 100, 8, level_colour(percent)) .. " " .. bold .. math.floor(percent + 0.5) .. "%" .. reset
				.. " " .. dim .. M.tokens(ctx) .. "/" .. M.tokens(window) .. reset
		elseif ctx then
			parts[#parts + 1] = "ctx " .. M.tokens(ctx)
		end
		if state.compactions > 0 then
			parts[#parts + 1] = "⟲" .. state.compactions
		end
		flow(out, parts, n)
		parts = {}
		for _, limit in ipairs(limits) do
			if tonumber(limit.used) then
				local left = limit.resets_at and limit.resets_at - now or nil
				local used = (left and left <= 0) and 0 or limit.used
				parts[#parts + 1] = limit.label .. " " .. cells(used / 100, 5, level_colour(used)) .. " " .. math.floor(used + 0.5) .. "%"
					.. ((left and left > 0) and (dim .. " ↻" .. time_left(left) .. reset) or "")
			end
		end
		if state.claude_ms > 0 then
			parts[#parts + 1] = dim .. who:lower() .. " " .. duration(state.claude_ms) .. reset
		end
		flow(out, parts, n)
		if #out == first_line then
			out[#out + 1] = dim .. "Nothing from " .. who .. " yet." .. reset
		end
	end)
end

--- The advisor's consults on a timeline from the first prompt to now.
local function advisor_box(out, state, cols, o)
	local consults = state.consults
	if #consults == 0 then
		return
	end
	local last = consults[#consults]
	local open = last.done == nil
	section(out, cols, "Advisor", { colour = purple, title = "ADVISOR · " .. (open and "consulting" or "on call"), right = "consults " .. #consults }, function(n)
		local from = (state.prompts[1] and M.epoch(state.prompts[1].at)) or consults[1].at or o.now
		local span = math.max(1, o.now - from)
		local line = {}
		for i = 1, n do
			line[i] = "─"
		end
		for _, c in ipairs(consults) do
			if c.at then
				line[math.max(1, math.min(n, math.floor((c.at - from) / span * (n - 1)) + 1))] = "◆"
			end
		end
		out[#out + 1] = purple .. table.concat(line) .. reset
		local facts = {}
		if last.at then
			facts[#facts + 1] = open and ("consulting " .. M.span(o.now - last.at)) or ("last " .. M.span(o.now - (last.done or last.at)) .. " ago")
		end
		if last.done and last.at then
			facts[#facts + 1] = "took " .. M.span(last.done - last.at)
		end
		out[#out + 1] = table.concat(facts, dim .. " · " .. reset)
	end)
end

local verdict_colours = { allowed = mint, classifier = aqua, you = blue, denied = red }
local verdict_marks = { allowed = "✓", classifier = "✓", you = "✓", denied = "✗" }

--- The gate: a cell for each latest permission check, the totals, and the
--- families, each opening its last 5 checks. `o.gate` is the family open.
local function gate_box(out, state, cols, o)
	local gate = state.gate
	if gate.total == 0 then
		return
	end
	section(out, cols, "Gate", { colour = mint, title = "GATE · permissions", right = gate.total .. " checks" }, function(n)
		local from = math.max(1, #gate.checks - n * 2 + 1)
		local row = {}
		for i = from, #gate.checks do
			local c = gate.checks[i]
			local cell = c.verdict == "denied" and "✗" or "⣿"
			row[#row + 1] = (c.sub and dim or "") .. verdict_colours[c.verdict] .. cell .. reset
			if #row == n then
				out[#out + 1] = table.concat(row)
				row = {}
			end
		end
		if #row > 0 then
			out[#out + 1] = table.concat(row)
		end
		local v = gate.verdicts
		flow(out, {
			mint .. "■" .. reset .. " " .. v.allowed .. " allowed",
			aqua .. "■" .. reset .. " " .. v.classifier .. " classifier",
			v.you > 0 and (blue .. "■" .. reset .. " " .. v.you .. " you") or nil,
			(v.denied > 0 and red or dim) .. "✗" .. reset .. " " .. v.denied .. " denied",
		}, n)
		local parts, ranges, column = {}, {}, 1
		for _, f in ipairs({ { "f", "file" }, { "s", "shell" }, { "o", "other" } }) do
			local text = f[1] .. ": " .. f[2] .. " " .. gate.families[f[2]]
			local shown = o.gate == f[2] and ("\27[7m" .. text .. reset) or text
			parts[#parts + 1] = shown
			ranges[#ranges + 1] = { from = column, to = column + M.width(text) - 1, action = { kind = "gate", family = f[2] } }
			column = column + M.width(text) + 2
		end
		out[#out + 1] = table.concat(parts, "  ")
		out.actions[#out] = { ranges = ranges }
		if o.gate then
			local shown = 0
			for i = #gate.checks, 1, -1 do
				local c = gate.checks[i]
				if c.family == o.gate then
					out[#out + 1] = verdict_colours[c.verdict] .. verdict_marks[c.verdict] .. reset .. " " .. c.tool
						.. (c.target ~= "" and (" " .. dim .. c.target .. reset) or "")
					shown = shown + 1
					if shown == 5 then
						break
					end
				end
			end
		end
	end)
end

--- Whether a subagent runs: it isn't finished, and, as one of a team never
--- gets the finished mark, its transcript changed in the last 5 minutes.
function M.agent_running(a, now)
	return not a.finished and not (a.last and now - a.last > 300)
end

--- The subagents as swimlanes on one time axis, the latest 8, newest first.
--- A running one has a pulsing ● and its lane in lavender. A click on a lane
--- opens its type, context, steps, last tool calls and answer.
local function agents_box(out, state, cols, o)
	local agents = o.agents or {}
	if #agents == 0 then
		return
	end
	local running = 0
	local from, to = math.huge, 0
	local first = math.max(1, #agents - 7)
	for i = first, #agents do
		local a = agents[i]
		if a.start then
			from = math.min(from, a.start)
			to = math.max(to, M.agent_running(a, o.now) and o.now or (a.last or a.start))
		end
	end
	for _, a in ipairs(agents) do
		if M.agent_running(a, o.now) then
			running = running + 1
		end
	end
	section(out, cols, "Agents", { colour = lavender, title = "AGENTS · " .. running .. " running", right = #agents .. " total" }, function(n)
		local label_w = math.max(8, math.floor(n * 0.4))
		local time_w = 7
		local bar_w = n - label_w - time_w - 2
		for i = #agents, first, -1 do
			local a = agents[i]
			local pulse = math.floor(o.now) % 2 == 0 and (bold .. lavender .. "●") or (lavender .. "●")
			local live = M.agent_running(a, o.now)
			local mark = a.finished and (mint .. "✓" .. reset) or live and (pulse .. reset) or (dim .. "○" .. reset)
			local lane = live and lavender or a.finished and dim .. mint or dim
			local label = pad(mark .. " " .. i .. ": " .. (a.description or a.type or "agent"), label_w)
			local stop = live and o.now or (a.last or a.start)
			local took = a.start and M.clock(stop - a.start) or ""
			local bar = ""
			if bar_w >= 4 then
				local cells_on = {}
				local span = math.max(1, to - from)
				local s = a.start and math.floor((a.start - from) / span * (bar_w - 1)) + 1 or 1
				local e = a.start and math.max(s, math.floor((stop - from) / span * (bar_w - 1)) + 1) or 0
				for c = 1, bar_w do
					cells_on[c] = (c >= s and c <= e) and (lane .. (live and "━" or "─") .. reset) or (dim .. "·" .. reset)
				end
				bar = " " .. table.concat(cells_on)
			end
			out[#out + 1] = label .. bar .. " " .. string.rep(" ", time_w - M.width(took)) .. took
			out.actions[#out] = { kind = "agent", id = a.id }
			if o.open_agents and o.open_agents[a.id] then
				flow(out, {
					dim .. (a.type or "agent") .. reset,
					a.context and (dim .. "ctx " .. M.tokens(a.context) .. reset),
					dim .. (a.steps or 0) .. " steps" .. reset,
				}, n)
				for t = math.max(1, #(a.tools or {}) - 2), #(a.tools or {}) do
					out[#out + 1] = "  " .. lavender .. "›" .. reset .. " " .. a.tools[t]
				end
				if a.answer then
					add(out, M.wrap(a.answer, n, "  " .. dim, "  " .. dim, 2))
				end
			end
		end
	end)
end

--- Claude's background tasks that run right now, newest first, as Claude
--- Code's own list shows them; no box with none. Shells are green and monitors blue.
local function processes_box(out, state, cols, o)
	local procs = o.processes or {}
	if #procs == 0 then
		return
	end
	section(out, cols, "Processes", { colour = teal, title = "PROCESSES · " .. #procs .. " running" }, function(n)
		for _, p in ipairs(procs) do
			local took = M.clock(p.age)
			local colour = p.kind == "monitor" and blue or mint
			local mark = (math.floor(o.now) % 2 == 0 and bold or "") .. colour .. "●" .. reset .. " "
			local tag = "  " .. colour .. p.kind .. reset
			local room = n - M.width(took) - 1 - M.width(tag) - 2
			out[#out + 1] = pad(mark .. M.clip(p.name, math.max(1, room)) .. tag, n - M.width(took) - 1) .. " " .. took
		end
	end)
end

--- Questions waiting for an answer, then open tasks; no box with none.
local function open_box(out, state, cols)
	local items = {}
	for id in pairs(state.waiting) do
		local tool = state.tools[id]
		if tool.name == "AskUserQuestion" then
			for _, q in ipairs(tool.input.questions or {}) do
				items[#items + 1] = { "?", q.question }
			end
		else
			items[#items + 1] = { "?", "Plan awaiting approval: " .. M.plan_title(tool.input.plan) }
		end
	end
	for _, q in ipairs(M.reply_questions(state)) do
		items[#items + 1] = { "?", q }
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
			items[#items + 1] = { status_marks[t.status] or "○", t.text }
		end
	end
	if #items == 0 then
		return
	end
	section(out, cols, "Open", { colour = gold, title = "OPEN", right = tostring(#items) }, function(n)
		for _, item in ipairs(items) do
			local mark = item[1] == "?" and (yellow .. "? " .. reset) or (item[1] .. " ")
			add(out, M.wrap(item[2], n, mark, "  "))
		end
	end)
end

--- The running turn, or the last one: how long, the agents it started, edits,
--- and errors; then tests and failed commands, each opening
--- its list.
local function receipt_box(out, state, cols, o)
	local turn = state.turn
	if not turn.at and #state.tests == 0 and #state.failures == 0 then
		return
	end
	local running = M.running(state)
	local title
	if running then
		title = orange .. spin(o.now) .. " turn " .. M.span(o.now - turn.at) .. reset
	elseif turn.ms then
		title = mint .. "✓" .. reset .. bold .. " last turn " .. M.span(turn.ms / 1000)
	else
		title = "turns"
	end
	section(out, cols, "Receipt", { colour = orange, title = title, right = "" }, function(n)
		if turn.at then
			local function count(k, one)
				return k .. " " .. one .. (k == 1 and "" or "s")
			end
			flow(out, {
				count(turn.agents, "agent"),
				count(turn.edits, "edit"),
				(turn.errors > 0 and red or "") .. count(turn.errors, "error") .. reset,
			}, n)
		end
		local passed, failed = 0, 0
		for _, t in ipairs(state.tests) do
			if t.ok then
				passed = passed + 1
			else
				failed = failed + 1
			end
		end
		local tests = "tests " .. #state.tests .. (#state.tests > 0 and (" " .. green .. "✓" .. passed .. reset .. " " .. (failed > 0 and red or dim) .. "✗" .. failed .. reset) or "")
		local fails = "failed commands " .. #state.failures
		local tw = M.width(tests)
		out[#out + 1] = (o.show == "tests" and ("\27[7m" .. tests .. reset) or tests) .. "  " .. (o.show == "failed" and ("\27[7m" .. fails .. reset) or fails)
		out.actions[#out] = { ranges = {
			{ from = 1, to = tw, action = { kind = "show", what = "tests" } },
			{ from = tw + 3, to = tw + 2 + M.width(fails), action = { kind = "show", what = "failed" } },
		} }
		if o.show == "tests" then
			for i = #state.tests, math.max(1, #state.tests - 7), -1 do
				local t = state.tests[i]
				out[#out + 1] = (t.ok and (green .. "✓ ") or (red .. "✗ ")) .. reset .. M.mask(t.command)
			end
		elseif o.show == "failed" then
			for i = #state.failures, math.max(1, #state.failures - 7), -1 do
				local f = state.failures[i]
				out[#out + 1] = red .. "✗ " .. reset .. M.mask(f.command)
				out[#out + 1] = "  " .. dim .. M.mask(f.error) .. reset
			end
		end
	end)
end

local log_colours = { main = orange, agent = lavender, gate = mint, advisor = purple }

--- The session log, newest at the bottom: as many of the latest events as the
--- rows under the other boxes hold, or, when those fill the screen, a screen
--- of them to scroll down to.
local function log_box(out, state, cols, o)
	local log = state.log
	if #log == 0 then
		return
	end
	local frame = cols >= M.box_min and 3 or 2
	local rows = o.rows or 0
	local room = rows - #out - frame
	if room < 3 then
		room = math.max(3, rows - frame)
	end
	section(out, cols, "Log", { colour = grey, title = "LOG", right = tostring(#log) }, function(n)
		for i = math.max(1, #log - room + 1), #log do
			local e = log[i]
			local when = e.at and os.date("%H:%M:%S", e.at) or "--:--:--"
			out[#out + 1] = dim .. when .. reset .. " " .. pad((log_colours[e.who] or grey) .. e.who, 8) .. e.text
		end
	end)
end

--- Everything on the Info tab. opts: status (the status line's saved input),
--- now, folded, focus, agents, gate (the family open), open_agents, show
--- ("tests" or "failed"), rows (the tab's height, which the log fills),
--- processes (from M.processes).
--- `ticking` is true while a clock runs.
local week_days = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local month_names = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- The time, "18:04", and the date, "Sun · 22 Nov 2026", written out here,
--- as this runtime's os.date gives day names in lower case.
function M.date_time(now)
	local t = os.date("*t", now)
	return string.format("%02d:%02d", t.hour, t.min), string.format("%s · %d %s %d", week_days[t.wday], t.day, month_names[t.month], t.year)
end

function M.info_lines(state, cols, opts)
	local o = opts or {}
	o.now = o.now or os.time()
	local out = new_lines(o.folded, o.focus)
	local time, date = M.date_time(o.now)
	out[#out + 1] = teal .. "◷ " .. reset .. bold .. time .. reset .. "  " .. grey .. date .. reset
	main_box(out, state, cols, o)
	advisor_box(out, state, cols, o)
	gate_box(out, state, cols, o)
	agents_box(out, state, cols, o)
	processes_box(out, state, cols, o)
	open_box(out, state, cols)
	receipt_box(out, state, cols, o)
	log_box(out, state, cols, o)
	out.ticking = M.running(state)
	for _, a in ipairs(o.agents or {}) do
		out.ticking = out.ticking or M.agent_running(a, o.now)
	end
	out.ticking = out.ticking or #(o.processes or {}) > 0
	return out
end

-- Last Turn ------------------------------------------------------------------

--- The Last Turn scope, from the hunks in the transcript.
function M.turn_data(state, root)
	local rows, added, removed = {}, 0, 0
	for _, path in ipairs(state.turn.order) do
		local f = state.turn.files[path]
		rows[#rows + 1] = { path = short_path(path, root), mark = f.created and "A" or f.deleted and "D" or "M", diff = "patch", absolute = path }
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

local diff_label, view_label = "Diff: ", "View: "

--- The floats an earlier diff or Rex View left in a window; one replaces the
--- other.
function M.old_diffs(window)
	local found = {}
	for _, l in ipairs(window.layers or {}) do
		if l.kind ~= "tiled" then
			for _, b in ipairs(l.blocks or {}) do
				local label = b.label or ""
				if label:sub(1, #diff_label) == diff_label or label:sub(1, #view_label) == view_label then
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

--- The process ID of the agent in a pane's `process` call, whichever agent it is.
function M.agent_pid(process)
	local _, _, pid = agents.in_process(process)
	return pid
end
M.claude_pid = M.agent_pid
M.project_dir = agents.claude.project_dir
M.transcript = agents.claude.transcript

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
	--- Section name -> true when folded, shared by all panes through settings.
	folded = settings.folded(settings_dir),
	--- Tab name -> the highlighted section's name.
	focus = {},
	--- The gate family whose last checks Info shows, if any.
	gate_open = nil,
	--- Subagent ID -> true when its lane is open on Info.
	open_agents = {},
	--- "tests" or "failed" when the receipt shows that list.
	show = nil,
	--- The tab's last built view; cleared by anything that changes it.
	cache = nil,
	state = M.new_state(),
}

--- The name of the agent beside the panel.
local function agent_name()
	return panel.agent and panel.agent.name or "Claude"
end

-- Background work -----------------------------------------------------------
-- git and gh run as tasks, coroutines the main loop steps between key reads,
-- so the pane keeps taking keys while they run. A task must never yield inside
-- pcall: this runtime crashes on it.

local tasks = {}

--- Starts `fn` as a task, unless one named `name` is still running.
local function spawn(name, fn)
	if tasks[name] then
		return false
	end
	tasks[name] = coroutine.create(fn)
	return true
end

--- Runs a command: in a task, without blocking, polling it each time the task
--- is stepped and stopping it after `limit` seconds, 5 by default; elsewhere,
--- as exec does.
local function run(argv, limit)
	if not coroutine.running() then
		return exec(argv)
	end
	local ok, h = pcall(rex.exec.start, argv, {})
	if not ok then
		return nil
	end
	local deadline = os.clock() + (limit or 5)
	while true do
		local r = h:wait(0)
		if r then
			return r
		end
		if os.clock() > deadline then
			pcall(h.kill, h)
			return nil
		end
		coroutine.yield("wait")
	end
end

--- Steps every task: one waiting on a command once, and one working for up to
--- 20 ms. True when one ended, as the view then needs building again.
local function step_tasks()
	local ended = false
	for name, co in pairs(tasks) do
		local start = os.clock()
		repeat
			local ok, why = coroutine.resume(co)
			if not ok then
				panel.notice = tostring(why)
			end
		until coroutine.status(co) == "dead" or why == "wait" or os.clock() - start > 0.02
		if coroutine.status(co) == "dead" then
			tasks[name] = nil
			ended = true
		end
	end
	return ended
end

M.spawn, M.run, M.step_tasks = spawn, run, step_tasks

-- The adapters' lookups (ps, sqlite3, ls) don't block key reads either.
agents.util.exec = function(argv)
	return run(argv)
end


--- Moves the pane to the repository of the directory Claude works in.
local function follow(cwd)
	if not cwd or cwd == panel.cwd then
		return
	end
	panel.cwd = cwd
	local r = run({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
	local root = r and r.ok and (r.stdout:gsub("%s+$", "")) or cwd
	if root ~= panel.root then
		panel.root = root
		rex.call("session.set_block_label", {
			session_id = panel.session_id,
			block_id = panel.block_id,
			label = "Sidecar: " .. (root:match("[^/]+$") or root),
		})
	end
end


--- The session's subagents, as its agent lists them, oldest first. A
--- finished one is read no more.
local function read_agents(state, sess)
	state.agents = state.agents or {}
	local done = {}
	for id, a in pairs(state.agents) do
		done[id] = a.finished or nil
	end
	local status = state.subagent_status or {}
	for _, sub in ipairs(sess.agent.subagents(sess, os.time(), done)) do
		local a = state.agents[sub.id]
		if not a then
			a = M.new_agent(sub.id, sess.agent.id)
			state.agents[sub.id] = a
		end
		-- Claude marks a finished subagent; a Codex parent's rollout says when
		-- its subagent finished, or got more work.
		local finished = sub.finished == true or status[sub.id] == "completed" or status[sub.id] == "interrupted"
		if a.finished and not finished then
			a.finished = false
		end
		if not a.finished then
			a.type, a.description = sub.type, sub.description
			if sub.transcript then
				M.read_agent(a, sub.transcript, state.gate)
			end
			a.finished = finished
		end
	end
	local list = {}
	for _, a in pairs(state.agents) do
		list[#list + 1] = a
	end
	table.sort(list, function(x, y)
		return (x.start or 0) < (y.start or 0)
	end)
	state.agent_list = list
end


local function gather()
	local size = rex.block.call(terminal, "size", { session_id = panel.session_id, block_id = panel.block_id })
	if size and size.columns then
		panel.cols, panel.rows = size.columns, size.rows
	end

	local process = panel.claude
		and rex.block.call(terminal, "process", { session_id = panel.session_id, block_id = panel.claude })
	local adapter, sess = agents.session(process, panel.session_id, panel.claude)
	panel.agent = adapter or panel.agent
	panel.sess = sess
	local pid = sess and sess.pid or M.agent_pid(process)
	local path, cwd = sess and sess.transcript, sess and sess.cwd
	panel.claude_pid = pid
	follow(cwd)

	panel.folded = settings.folded(settings_dir)

	if path then
		-- A transcript is read into a state of its own, shown once it's read.
		local state = panel.state
		if path ~= state.path then
			state = M.new_state(adapter.id)
			state.path = path
		end
		if M.read_new(state, path) == "reset" then
			state = M.new_state(adapter.id)
			state.path = path
			M.read_new(state, path)
		end
		panel.state = state
		panel.status = sess.status
		read_agents(state, sess)
		local ps = pid and run({ "/bin/ps", "-axo", "pid=,ppid=,etime=,comm=" })
		-- The tasks come from the transcript, as Claude Code lists them, each
		-- with a live shell of Claude's.
		local live = (ps and ps.ok) and M.processes(pid, ps.stdout, state.monitors, os.time()) or {}
		panel.processes = {}
		if #live > 0 then
			local now = os.time()
			for _, t in ipairs(M.running_tasks(state, now, live)) do
				panel.processes[#panel.processes + 1] = { name = t.name, kind = t.monitor and "monitor" or "shell", age = t.at and (now - t.at) or 0 }
			end
		end
	end

	panel.gathered = true
end

-- Tab plugins ---------------------------------------------------------------
-- Each Lua file in tabs/ and in ~/.config/rex/sidecar-tabs adds a tab; see the
-- README.

--- Tab name -> { tab = the table its file returned, due = when its next
--- refresh starts }.
local plugins = {}
M.plugins = plugins

--- Every tab after Info, in the order added.
M.tab_names = {}

local function has_tab(name)
	for _, tab in ipairs(M.tab_names) do
		if tab == name then
			return true
		end
	end
	return name == "Info"
end

--- Puts the tabs to show in M.tabs: Info, then the others in the saved order,
--- and after them, in the order added, those the saved order doesn't name.
--- A tab with `hidden` set is hidden until the saved order names it. A
--- hidden open tab gives way to Info.
local function arrange()
	local saved, hidden = settings.tabs(settings_dir)
	local order, listed = {}, {}
	for i, list in ipairs({ saved, M.tab_names }) do
		for _, name in ipairs(list) do
			if not listed[name] and has_tab(name) and name ~= "Info" then
				listed[name] = true
				order[#order + 1] = name
				if i == 2 and plugins[name].tab.hidden then
					hidden[name] = true
				end
			end
		end
	end
	local tabs = { "Info" }
	for _, name in ipairs(order) do
		if not hidden[name] then
			tabs[#tabs + 1] = name
		end
	end
	panel.tab_order, panel.hidden_tabs, M.tabs = order, hidden, tabs
	if hidden[panel.tab] then
		panel.tab = "Info"
	end
	panel.cache = nil
end

--- Loads each Lua file in `path` as a tab, added after the others in file
--- name order. A file gets this module as its argument. A file that fails to
--- load gets a tab, named after the file, that shows the error.
function M.load_plugins(path)
	local r = exec({ "/bin/ls", path })
	local files = {}
	for file in (r and r.ok and r.stdout or ""):gmatch("[^\n]+") do
		if file:match("%.lua$") then
			files[#files + 1] = file
		end
	end
	table.sort(files)
	for _, file in ipairs(files) do
		local ok, tab = pcall(function()
			return assert(loadfile(path .. file))(M)
		end)
		if ok and not (type(tab) == "table" and type(tab.name) == "string" and not has_tab(tab.name)) then
			ok, tab = false, file .. " must return a table with a tab name not yet in use."
		end
		if not ok then
			local message = tostring(tab)
			tab = {
				name = file,
				view = function(cols)
					return { lines = M.wrap(message, cols, red, red) }
				end,
			}
		end
		plugins[tab.name] = { tab = tab, due = 0 }
		M.tab_names[#M.tab_names + 1] = tab.name
	end
	arrange()
end

--- Starts the refresh of each shown plugin tab that is due, as a task. The
--- next is due `interval` seconds, 60 by default, after this one starts.
local function refresh_plugins(now)
	for name, p in pairs(plugins) do
		if p.tab.refresh and not panel.hidden_tabs[name] and now >= p.due and spawn("tab " .. name, p.tab.refresh) then
			p.due = now + (p.tab.interval or 60)
		end
	end
end

--- A plugin tab's view. An error in the plugin's view shows in its place. A
--- view without pinned lines gets the pane's notice, such as an error in one
--- of the plugin's tasks.
local function plugin_view(tab)
	local cols = panel.cols - 1
	local ok, v = pcall(tab.view, cols)
	if not ok or type(v) ~= "table" then
		v = { lines = M.wrap(tostring(v), cols, red, red) }
	end
	local pinned = v.pinned or { panel.notice and (red .. panel.notice .. reset) }
	return { lines = v.lines or {}, pinned = pinned, hits = v.hits or {}, actions = v.actions or {}, sections = v.sections or {}, selected = v.selected }
end

--- The tab settings, in place of the open tab's view: Info, then each other
--- tab in its order, shown or hidden. `at` is the selected tab's place.
local function tabs_view(cols, at)
	local lines, actions = {}, {}
	M.box(lines, actions, cols, grey, bold .. "Tabs" .. reset, "", function()
		lines[#lines + 1] = "  " .. green .. "✓" .. reset .. " Info" .. dim .. "  always shown" .. reset
		for i, name in ipairs(panel.tab_order) do
			local mark = panel.hidden_tabs[name] and (dim .. "○" .. reset) or (green .. "✓" .. reset)
			lines[#lines + 1] = (i == at and (cyan .. "› " .. reset) or "  ") .. mark .. " " .. name
			actions[#lines] = { kind = "show_tab", name = name }
		end
	end)
	lines[#lines + 1] = ""
	lines[#lines + 1] = dim .. "Space shows or hides  J K move  Esc closes" .. reset
	return { lines = lines, pinned = {}, hits = {}, actions = actions, sections = {}, selected = at + 2 }
end

--- Shows or hides a tab, and saves the choice.
local function toggle_tab(name)
	if name then
		panel.hidden_tabs[name] = not panel.hidden_tabs[name] or nil
		pcall(settings.set_tabs, settings_dir, panel.tab_order, panel.hidden_tabs)
		arrange()
	end
end

--- Moves the tab at place `at` in the order one place, by `step`, and saves
--- the order.
local function move_tab(at, step)
	local order = panel.tab_order
	if order[at] and order[at + step] then
		order[at], order[at + step] = order[at + step], order[at]
		panel.arranging = at + step
		pcall(settings.set_tabs, settings_dir, order, panel.hidden_tabs)
		arrange()
	end
end

--- A key while the tab settings are open; true when it took the key.
local function tabs_key(k)
	local at = panel.arranging
	if k == "j" or k == "down" or k == "k" or k == "up" then
		local step = (k == "j" or k == "down") and 1 or -1
		panel.arranging = math.max(1, math.min(#panel.tab_order, at + step))
	elseif k == " " or k == "\r" or k == "\n" then
		toggle_tab(panel.tab_order[at])
	elseif k == "J" or k == "K" then
		move_tab(at, k == "J" and 1 or -1)
	elseif k == "escape" or k == "," then
		panel.arranging = nil
	else
		return false
	end
	return true
end

local function build(tab)
	if panel.arranging then
		return tabs_view(panel.cols - 1, panel.arranging)
	end
	if plugins[tab] then
		return plugin_view(plugins[tab].tab)
	end
	if not panel.gathered then
		local lines = { dim .. "Reading the session…" .. reset }
		return { lines = lines, pinned = {}, hits = {}, actions = {}, sections = {} }
	end
	local lines
	if not panel.state.path then
		lines = { dim .. "No " .. agent_name() .. " session found for this pane." .. reset }
	else
		lines = M.info_lines(panel.state, panel.cols - 1, {
			status = panel.status,
			agent_name = agent_name(),
			session_name = panel.sess and panel.sess.name,
			folded = panel.folded,
			focus = panel.focus.Info,
			agents = panel.state.agent_list,
			gate = panel.gate_open,
			open_agents = panel.open_agents,
			show = panel.show,
			rows = M.page(panel.rows, 0),
			processes = panel.processes,
		})
	end
	return { lines = lines, pinned = {}, hits = {}, actions = lines.actions or {}, sections = lines.sections or {}, ticking = lines.ticking }
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
		if c.selected then
			s = math.max(c.selected - page, math.min(s, c.selected - 1))
		end
	end
	s = math.max(0, math.min(s, #c.lines - page))
	panel.scroll[panel.tab] = s
	local badges = {}
	for name, p in pairs(plugins) do
		if p.tab.badge then
			local ok, badge = pcall(p.tab.badge)
			badges[name] = ok and badge and tostring(badge) or nil
		end
	end
	local frame, ranges = M.frame(M.tabs, panel.tab, c.lines, s, panel.cols, panel.rows, { pinned = c.pinned, badges = badges })
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
	panel.arranging = nil
	panel.cache = nil
	if plugins[tab] and plugins[tab].tab.activate then
		plugins[tab].tab.activate()
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

local function toggle_fold(name)
	local on = not panel.folded[name]
	panel.folded[name] = on or nil
	panel.cache = nil
	pcall(settings.set_folded, settings_dir, name, on)
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

--- Whether this pane has offered to install leaf.
local leaf_offered = false

--- Offers once per sidecar, unless declined for good, to install leaf, which
--- the float would use. The offer is a palette prompt, which only an action can
--- show, so it runs in the background through `rex do`.
local function offer_leaf()
	if leaf_offered or leaf.path(home) or not settings.leaf_ask(settings_dir) then
		return
	end
	leaf_offered = true
	pcall(rex.exec.start, { rex_binary, "--autostart=false", "do", "rex_sidecar_leaf_install",
		"session_id=" .. panel.session_id, "block_id=" .. panel.block_id }, { detach = true, stdout = false, stderr = false })
end

--- Opens a float over this pane's tab, replacing an earlier diff or Rex View.
--- Returns a message when it can't.
local function open_float(label, command, cwd)
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
	local created, opened = rex.call("session.new_layer", {
		session_id = panel.session_id,
		window_id = window.window_id,
		bounds = { 0.1, 0.075, 0.8, 0.85 },
		focus = true,
		layout = {
			block = {
				flavor = terminal .. ".shell",
				label = label,
				options = { command = command, cwd = cwd },
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
	offer_leaf()
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

local function act(action)
	local plugin = plugins[panel.tab]
	if action.kind == "show_tab" then
		toggle_tab(action.name)
	elseif plugin and not panel.arranging and action.kind ~= "tab" and action.kind ~= "fold" then
		if plugin.tab.act then
			plugin.tab.act(action)
		end
		panel.cache = nil
	elseif action.kind == "tab" then
		set_tab(action.tab)
	elseif action.kind == "fold" then
		toggle_fold(action.name)
	elseif action.kind == "gate" then
		panel.gate_open = panel.gate_open ~= action.family and action.family or nil
		panel.cache = nil
	elseif action.kind == "agent" then
		panel.open_agents[action.id] = not panel.open_agents[action.id] or nil
		panel.cache = nil
	elseif action.kind == "show" then
		panel.show = panel.show ~= action.what and action.what or nil
		panel.cache = nil
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
		k = escape() or "escape"
	end
	if type(k) == "table" then
		mouse(k)
		return
	end
	-- The tab settings take their keys first, and then a plugin tab.
	local plugin, taken = plugins[panel.tab], false
	if panel.arranging then
		taken = tabs_key(k)
	elseif plugin and plugin.tab.key then
		taken = plugin.tab.key(k)
	end
	if taken then
		panel.cache, panel.reveal = nil, true
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
		scroll_by(1)
	elseif k == "k" or k == "up" then
		scroll_by(-1)
	elseif k == " " or k == "pagedown" then
		scroll_by(page)
	elseif k == "b" or k == "pageup" then
		scroll_by(-page)
	elseif k == "g" then
		panel.scroll[panel.tab] = 0
	elseif k == "," then
		panel.arranging, panel.cache = 1, nil
	elseif panel.tab == "Info" and (k == "f" or k == "s" or k == "o") then
		act({ kind = "gate", family = ({ f = "file", s = "shell", o = "other" })[k] })
	elseif k == "n" then
		next_section(1)
	elseif k == "p" then
		next_section(-1)
	elseif k == "\n" or k == "\r" then
		fold_focused()
	end
end

M.key, M.act, M.current, M.refresh_plugins = key, act, current, refresh_plugins
-- What the tab plugins in this folder use besides the drawing helpers.
M.panel, M.dir, M.settings, M.settings_dir, M.rex_binary = panel, dir, settings, settings_dir, rex_binary
M.agent_name = agent_name
M.open_float, M.diff_label, M.view_label = open_float, diff_label, view_label
M.section, M.new_lines, M.fold_marks = section, new_lines, fold_marks
arrange()

if REX_SIDECAR_TEST then
	return M
end

M.load_plugins(dir .. "tabs/")
M.load_plugins(home .. "/.config/rex/sidecar-tabs/")

-- Keys arrive one at a time, and a read gives up after a tenth of a second,
-- so the loop steps the tasks and redraws without waiting for a key. Modes 1000 and 1006 report
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
	if now - gathered >= 2 and now - typed >= 1 and spawn("gather", gather) then
		gathered = now
		-- Other panes change the tab settings too.
		arrange()
	end
	if now - typed >= 1 then
		refresh_plugins(now)
	end
	if step_tasks() then
		panel.cache = nil
		dirty = true
	end
	-- Running clocks tick once a second.
	if panel.cache and panel.cache.ticking and os.clock() - drawn >= 1 then
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
