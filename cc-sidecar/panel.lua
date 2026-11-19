-- Runs in a sidecar pane, with three tabs: what changed, by scope (Changes),
-- how the Claude beside it stands (Info), and the files and links Claude's
-- replies mention (Artifacts). The watcher
-- passes the Claude pane's block ID and its directory (the repository root, in
-- one) as `claude=` and `cwd=`. The session is read from Claude Code's own
-- files, so no Claude Code setting is needed. With CC_SIDECAR_TEST set, this
-- file returns its functions instead of running.

local M = {}

local terminal = "com.superlogical.terminal"
local home = os.getenv("HOME") or ""
local dir = debug.getinfo(1, "S").source:match("^@?(.*/)") or "./"
local settings = dofile(dir .. "settings.lua")
local agents = dofile(dir .. "../agents/init.lua")
local mentions = dofile(dir .. "mentions.lua")
local rex_binary = home
	.. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
local viewer = dir .. "../plugins/rex-view/skills/rex-view/scripts/viewer"

M.tabs = { "Info", "Changes", "Artifacts" }

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
M.first_line, M.short_path = first_line, short_path

--- A reader for each agent's transcripts, by adapter ID; see parsers/.
local parsers = {}
for _, id in ipairs({ "claude", "codex" }) do
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
			local line = text:sub(pos, nl - 1):gsub("\\u001b%[[%d;?]*%a", "")
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
--- newest first, as cc-crab-pond finds them. A process has only its program's
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
M.colours = { orange = orange, lavender = lavender, mint = mint, purple = purple, gold = gold, teal = teal, blue = blue, grey = grey }

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
	for line in (last.text .. "\n"):gmatch("([^\n]*)\n") do
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
function M.info_lines(state, cols, opts)
	local o = opts or {}
	o.now = o.now or os.time()
	local out = new_lines(o.folded, o.focus)
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

-- Artifacts -----------------------------------------------------------------

--- The Artifacts tab: the Search Panel link, pinned, then a section for each
--- category of what Claude's replies mention. `groups` comes from
--- mentions.group; a click on a row opens it as the Search Panel's Enter does.


--- `titles` maps a PR's link to its title, when it's known.
function M.artifacts_view(groups, cols, folded, focus, notice, titles, who)
	titles = titles or {}
	who = who or "Claude"
	local out = new_lines(folded, focus)
	local link = "Search Panel"
	local built = {
		lines = out,
		pinned = { bold .. teal .. link .. reset .. dim .. "  ↗ all of " .. who .. "'s replies" .. reset, notice and (red .. notice .. reset) or "" },
		hits = { { { from = 1, to = M.width(link), action = { kind = "view_panel" } } } },
		rows = {},
	}
	if #groups == 0 then
		out[1] = dim .. "Nothing in " .. who .. "'s replies yet." .. reset
	end
	for _, g in ipairs(groups) do
		local n = cols
		local function row(label, note, target)
			if note == "" then
				out[#out + 1] = M.clip(label, n)
			else
				local room = math.max(1, n - M.width(note) - 2)
				out[#out + 1] = M.clip(label, room) .. "  " .. dim .. note .. reset
			end
			out.actions[#out] = { kind = "mention", row = target }
		end
		local style = mentions.styles[g.name] or mentions.styles.Other
		section(out, cols, g.name, { colour = style.colour, icon = style.icon, right = tostring(#g.rows) }, function(inner)
			n = inner
			for i, r in ipairs(g.rows) do
				if i > 10 then
					out[#out + 1] = dim .. "+" .. (#g.rows - 10) .. " more · Search Panel" .. reset
					out.actions[#out] = { kind = "view_panel" }
					break
				end
				if r.kind == "pr" then
					local title = titles[r.target]
					title = title and (dim .. (r.name:match("#%d+$") or r.name) .. reset .. " " .. title)
					local own = { kind = "link", target = r.target }
					if #r.rows + (r.direct and 1 or 0) <= 1 then
						local sub = r.rows[1]
						row(title or r.name, sub and sub.sub or "", sub or own)
					else
						row(title or r.name, "", own)
						for _, sub in ipairs(r.rows) do
							row("  " .. sub.sub, "", sub)
						end
					end
				elseif r.title then
					local key = r.target:match("/browse/(%u[%u%d]*%-%d+)") or r.label
					row(dim .. key .. reset .. " " .. r.title, "", r)
				else
					row(r.label, r.note or r.kind, r)
				end
			end
		end)
	end
	built.actions, built.sections = out.actions, out.sections
	return built
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
	local mark = v.tree and (teal .. tree_mark .. reset) or (dim .. tree_mark .. reset)
	local title = bold .. teal .. (v.title or "") .. reset
	if cols >= M.box_min then
		-- The header is a box of its own, pinned: branch, totals and tree mark on
		-- the top line, the scopes inside.
		local head, ranges = {}, {}
		M.box(head, nil, cols, teal, title, stats .. mark, function(n)
			local bar
			bar, ranges = M.scope_bar(v.scopes, v.scope, n)
			head[#head + 1] = bar
		end)
		for _, r in ipairs(ranges) do
			r.from, r.to = r.from + 2, r.to + 2
		end
		built.pinned = { head[1], head[2], head[3] }
		built.hits = { { { from = cols - 3, to = cols - 2, action = { kind = "tree" } } }, ranges }
	else
		local right = M.width(stats) + M.width(tree_mark)
		title = M.clip(title, math.max(1, cols - right - 1))
		built.pinned[1] = title .. reset .. string.rep(" ", math.max(1, cols - M.width(title) - right)) .. stats .. mark
		built.hits[1] = { { from = cols - 1, to = cols, action = { kind = "tree" } } }
		built.pinned[2] = ""
		built.pinned[3], built.hits[3] = M.scope_bar(v.scopes, v.scope, cols)
	end
	built.pinned[#built.pinned + 1] = v.notice and (red .. v.notice .. reset) or ""

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
		local count = bold .. teal .. group.title .. reset .. dim .. " " .. #group.rows .. reset
		local vs = data.vs and (dim .. "vs " .. data.vs .. reset) or ""
		M.box(out, built.actions, cols, teal, count, vs, function(n)
			if v.tree then
				tree_rows(out, built, group.rows, v.selected, n, v.folded or {})
			else
				list_rows(out, built, group, v.selected, group.title)
			end
		end)
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
	--- The Artifacts tab's categories, from every reply; see refresh_artifacts.
	artifacts = nil,
	--- The gate family whose last checks Info shows, if any.
	gate_open = nil,
	--- Subagent ID -> true when its lane is open on Info.
	open_agents = {},
	--- "tests" or "failed" when the receipt shows that list.
	show = nil,
	--- A PR's link -> its title, or false when it couldn't be looked up.
	titles = {},
	--- Scope -> the key of the selected row.
	selected = {},
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

local function git(...)
	local r = run({ "git", "-C", panel.root, ... })
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
	local r = run({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
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
--- opening Changes, on a new branch or repository, and after 5 minutes.
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
	local r = run({ "/bin/sh", "-c", 'export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"; cd "$1" && exec gh pr view --json number,baseRefName,state', "sh", panel.root })
	local pr = r and r.ok and M.pr_info(r.stdout) or nil
	pr_cache = { key = key, at = now, pr = pr }
	return pr
end

--- Looks up the titles of the PRs in Artifacts, from GitHub through `gh`, at
--- most 4 at a time. A title is looked up once while the panel runs, and a
--- failed lookup isn't tried again.
local function pr_titles(groups)
	local running = 0
	for name in pairs(tasks) do
		if name:sub(1, 6) == "title " then
			running = running + 1
		end
	end
	for _, g in ipairs(groups) do
		for _, r in ipairs(g.rows) do
			if running >= 4 then
				return
			end
			local url = r.target
			if r.kind == "pr" and panel.titles[url] == nil and spawn("title " .. url, function()
				local res = run({ "/bin/sh", "-c", 'export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"; exec gh pr view "$1" --json title --jq .title', "sh", url })
				local title = res and res.ok and res.stdout:gsub("%s+$", "") or ""
				panel.titles[url] = title ~= "" and title or false
			end) then
				running = running + 1
			end
		end
	end
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

--- Loads the scope on show, only that one. A load that a newer one replaced
--- while git ran keeps what it found to itself.
local scope_loads = 0
local function load_scope()
	scope_loads = scope_loads + 1
	local load = scope_loads
	local third, pr, ref = third_scope()
	local scope = M.pick_scope(M.scopes(panel.git, third), panel.scope)
	local data
	if scope == "Last Turn" then
		data = M.turn_data(panel.state, panel.root)
		if not panel.state.path then
			data.problem = "No " .. agent_name() .. " session found for this pane."
		end
	elseif scope == "Uncommitted" then
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
	if load == scope_loads then
		panel.third, panel.scope, panel.data = third, scope, data
		panel.cache = nil
	end
end

--- Loads the scope in the background, with the rows emptied when it's another
--- scope than the one shown.
local function reload_scope(switched)
	if switched then
		panel.data = { groups = {}, note = "Loading…" }
	end
	spawn("scope " .. (scope_loads + 1), load_scope)
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

--- The Artifacts tab's categories. Each reply is read once, as replies don't
--- change once Claude has moved on; all are read again when the transcript,
--- Claude's directory or the link patterns change.
local function refresh_artifacts()
	local patterns = settings.link_patterns(dir)
	local ok, encoded = pcall(rex.json.encode, patterns)
	local key = (panel.cwd or "") .. "\0" .. (ok and encoded or "")
	local a = panel.artifacts
	if not (a and a.key == key and a.state == panel.state) then
		a = { key = key, state = panel.state, per = {}, groups = {}, total = 0, rules = mentions.rules_for(patterns, panel.cwd) }
		panel.artifacts = a
		a.changed = true
	end
	local responses = panel.state.responses
	local lists = {}
	for i = #responses, 1, -1 do
		local r, done = responses[i], a.per[i]
		if not (done and done.seq == r.seq) then
			done = { seq = r.seq, rows = mentions.find({ r.text }, panel.cwd, a.rules) }
			a.per[i] = done
			a.changed = true
			if coroutine.running() and i % 20 == 0 then
				coroutine.yield()
			end
		end
		lists[#lists + 1] = done.rows
	end
	if a.changed or a.count ~= #responses then
		a.changed, a.count = false, #responses
		a.groups, a.total = mentions.group(lists)
	end
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

	panel.folded = settings.folded(dir)
	panel.folded_dirs = settings.folded_dirs(dir, panel.root)

	-- One status call: git status runs slowly in big repositories.
	local r = run({ "git", "-C", panel.root, "status", "--porcelain", "-b", "-z", "--untracked-files=all" })
	panel.git = r and r.ok or false
	panel.files, panel.branch, panel.head = {}, nil, true
	if panel.git then
		local status = M.status(r.stdout)
		panel.files, panel.branch, panel.head = status.files, status.branch, status.head
	end

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

	if panel.tab == "Changes" or not panel.data then
		load_scope()
	end
	panel.gathered = true
	refresh_artifacts()
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
			data = panel.data or { groups = {}, note = "Loading…" },
			notice = panel.notice,
		}, panel.cols - 1)
	end
	if not panel.gathered then
		local lines = { dim .. "Reading the session…" .. reset }
		return { lines = lines, pinned = {}, hits = {}, actions = {}, sections = {}, rows = {} }
	end
	if tab == "Artifacts" and panel.state.path then
		local a = panel.artifacts or { groups = {} }
		pr_titles(a.groups)
		return M.artifacts_view(a.groups, panel.cols - 1, panel.folded, panel.focus.Artifacts, panel.notice, panel.titles, agent_name())
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
	return { lines = lines, pinned = {}, hits = {}, actions = lines.actions or {}, sections = lines.sections or {}, rows = {}, ticking = lines.ticking }
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
	local found = panel.artifacts and panel.artifacts.total > 0 and tostring(panel.artifacts.total) or nil
	local badges = { Changes = count, Artifacts = found }
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
	panel.cache = nil
	if tab == "Changes" then
		pr_cache = nil
		reload_scope(false)
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
	reload_scope(true)
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
end

--- Opens a row's diff in a float.
local function open_diff(row)
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
	return open_float(diff_label .. (row.path:match("[^/]+$") or row.path), command, panel.root)
end

--- What a click on an Artifacts row does: the Search Panel's Enter.
local function open_mention(row)
	if row.kind == "link" then
		if row.target:match("^https?://") then
			exec({ "/usr/bin/open", row.target })
		end
		return
	end
	local f = io.open(viewer, "rb")
	local command = { viewer, row.target, row.line }
	if f then
		f:close()
	else
		command = { "/usr/bin/less", "-R", "--", row.target }
	end
	return open_float(view_label .. (row.target:match("[^/]+$") or row.target), command, row.target:match("^(.*)/[^/]*$"))
end

local function open_view_panel()
	if not panel.claude then
		return "No agent pane for this sidecar."
	end
	return open_float(view_label .. "Search Panel", { dir .. "view-picker", rex_binary, panel.session_id, panel.claude }, panel.cwd)
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
	elseif action.kind == "mention" then
		panel.notice = open_mention(action.row)
	elseif action.kind == "view_panel" then
		panel.notice = open_view_panel()
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
	elseif panel.tab == "Info" and (k == "f" or k == "s" or k == "o") then
		act({ kind = "gate", family = ({ f = "file", s = "shell", o = "other" })[k] })
	elseif panel.tab ~= "Changes" and k == "n" then
		next_section(1)
	elseif panel.tab ~= "Changes" and k == "p" then
		next_section(-1)
	elseif panel.tab ~= "Changes" and (k == "\n" or k == "\r") then
		fold_focused()
	end
end

if CC_SIDECAR_TEST then
	return M
end

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
