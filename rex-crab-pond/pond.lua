-- The crab pond: runs inside the "Crabs" pane that watcher.lua opens, and
-- draws what runs in this tab as pixel crabs: the tab's main agent (Claude
-- Code or Codex), then crabs for its subagents and background tasks, the
-- tab's other agents and the programs in its other panes. It reads each
-- agent's session through agents/init.lua, Rex's view of the tab and the
-- process list, and gathers them again every 2 seconds; the crabs move 4
-- times a second.

local dir = debug.getinfo(1, "S").source:match("^@?(.*/)")
local sprites = dofile(dir .. "sprites.lua")
local glyphs = dofile(dir .. "glyphs.lua")
local agents = dofile(dir .. "../agents/init.lua")

local M = {}

local terminal = "com.superlogical.terminal"

M.colors = {
	agent = "#4FB3A9",
	editor = "#6A8FD8",
	git = "#D9534F",
	build = "#E0A83A",
	server = "#8E6FD8",
	remote = "#A05FC8",
	shell = "#8C8C8C",
	monitor = "#5AB0F0",
	other = "#6DBE6D",
	text = "#D6D6D6",
	dim = "#8A8A8A",
	busy = "#46A758",
	idle = "#8A8A8A",
	bad = "#E5484D",
}

--- Per-agent colours and gradients come directly from each adapter's theme.
M.gradients = {}
for _, adapter in ipairs(agents.list) do
	local theme = agents.theme(adapter)
	M.colors[adapter.id] = theme.accent
	M.colors[adapter.id .. "_subagent"] = theme.agent or theme.accent
	if theme.gradient then
		M.gradients[adapter.id] = theme.gradient
	end
end
M.colors.subagent = M.colors.claude_subagent

--- Brand colours for an outfit's accent, such as the builder's hard hat. The
--- body keeps its kind's colour.
local program_accents = {
	go = "#00ADD8", -- Go gopher blue
	cargo = "#F74C00", rustc = "#F74C00", -- Ferris orange
	python = "#3776AB", python3 = "#3776AB", pip = "#3776AB",
	node = "#5FA04E",
	npm = "#CB3837", npx = "#CB3837",
	pnpm = "#F69220",
	yarn = "#2C8EBF",
	bun = "#FBF0DF", bunx = "#FBF0DF",
	tsc = "#3178C6",
	ruby = "#CC342D", rake = "#CC342D", bundle = "#CC342D",
	swift = "#F05138",
	dotnet = "#512BD4",
}

local outfit_of_kind = {
	agent = "robot",
	editor = "coder",
	git = "git",
	build = "builder",
	server = "server",
	remote = "diver",
	shell = "sleeper",
	monitor = "lookout",
	other = "plain",
}

local program_kinds = {
	editor = { "nvim", "vim", "vi", "hx", "helix", "emacs", "nano", "micro", "kak", "code", "zed" },
	git = { "git", "gh", "lazygit", "tig", "gitui", "jj" },
	build = {
		"go", "cargo", "rustc", "make", "cmake", "ninja", "npm", "npx", "pnpm", "yarn", "bun", "bunx",
		"node", "deno", "tsc", "jest", "vitest", "python", "python3", "pytest", "pip", "uv", "ruby",
		"rake", "bundle", "swift", "xcodebuild", "gradle", "mvn", "java", "dotnet", "mix", "elixir",
	},
	server = {
		"docker", "kubectl", "k9s", "helm", "psql", "postgres", "mysql", "mongod", "mongosh",
		"redis-server", "redis-cli", "nginx", "caddy", "sqlite3", "terraform",
	},
	remote = { "ssh", "mosh", "scp", "rsync", "sftp", "tailscale", "et" },
	shell = { "zsh", "bash", "fish", "sh", "dash", "nu", "login" },
	agent = { "codex", "agy", "pi", "gemini", "aider", "opencode", "cursor-agent", "amp", "goose", "crush", "qwen" },
}
local kind_of_program = {}
for kind, names in pairs(program_kinds) do
	for _, n in ipairs(names) do
		kind_of_program[n] = kind
	end
end

-- Text ----------------------------------------------------------------------

--- A number from a pattern capture. In this Lua a failed match passes no
--- value at all, which tonumber rejects.
local function num(capture)
	return capture and tonumber(capture) or nil
end

--- A path's last part. ps shows an exiting process's name in parentheses.
local function basename(path)
	return ((path or ""):match("([^/]*)/*$"):gsub("^%((.*)%)$", "%1"))
end

--- The number of characters in a UTF-8 string.
function M.width(s)
	return select(2, s:gsub("[^\128-\191]", ""))
end

--- s cut to n characters, ending in … when cut.
function M.clip(s, n)
	if n <= 0 then
		return ""
	end
	if M.width(s) <= n then
		return s
	end
	local out, count = {}, 0
	for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		if count == n - 1 then
			break
		end
		out[#out + 1] = ch
		count = count + 1
	end
	return table.concat(out) .. "…"
end

function M.number(n)
	n = n or 0
	if n >= 1e9 then
		return string.format("%.1fB", n / 1e9)
	elseif n >= 1e6 then
		return string.format("%.1fM", n / 1e6)
	elseif n >= 1e4 then
		return string.format("%.0fK", n / 1e3)
	elseif n >= 1e3 then
		return string.format("%.1fK", n / 1e3)
	end
	return tostring(math.floor(n))
end

function M.duration(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	local d, h = math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600)
	local m = math.floor(seconds % 3600 / 60)
	if d > 0 then
		return h > 0 and string.format("%dd%dh", d, h) or string.format("%dd", d)
	elseif h > 0 then
		return m > 0 and string.format("%dh%dm", h, m) or string.format("%dh", h)
	elseif m > 0 then
		return string.format("%dm", m)
	end
	return string.format("%ds", seconds)
end

--- Seconds from ps's elapsed time, [[dd-]hh:]mm:ss.
function M.etime(text)
	local d, rest = (text or ""):match("^(%d+)%-(.+)$")
	rest = rest or text or ""
	local parts = {}
	for n in rest:gmatch("%d+") do
		parts[#parts + 1] = tonumber(n)
	end
	local seconds = 0
	for _, n in ipairs(parts) do
		seconds = seconds * 60 + n
	end
	return seconds + (num(d) or 0) * 86400
end

local utc_offset = os.time() - os.time(os.date("!*t"))

--- The time of an ISO timestamp in UTC, such as 2026-10-29T14:52:52Z.
function M.iso_time(ts)
	local y, mo, d, h, mi, sec = (ts or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then
		return nil
	end
	return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec, isdst = false }) + utc_offset
end

-- Who is who --------------------------------------------------------------

--- The kind of crab for a program, and its plain name.
function M.program_kind(argv0)
	local name = basename(argv0):gsub("^%-", "")
	return kind_of_program[name:lower()] or "other", name
end

--- A program's brand colour for its outfit's accent, or nil.
function M.program_accent(name)
	return program_accents[name]
end

--- A Claude session's outfit, from its model and effort.
function M.claude_outfit(model, effort)
	model, effort = (model or ""):lower(), (effort or ""):lower()
	if model:find("fable") then
		return "wizard"
	elseif model:find("opus") then
		if effort == "max" then
			return "scientist"
		elseif effort == "xhigh" then
			return "painter"
		elseif effort == "high" then
			return "royal"
		elseif effort == "low" then
			return "ninja"
		end
		return "cowboy"
	elseif model:find("sonnet") then
		return "musician"
	elseif model:find("haiku") then
		return "gardener"
	end
	return "plain"
end

--- Words that pick a subagent's outfit; a word in its type or task that
--- starts with one counts ("reviewing" for "review"), and the longest one
--- wins ("docker" is a server, not a doc). One of three letters or fewer
--- counts only whole, or with -s, -es or -ing.
local outfit_words = {
	explorer = { "explor", "search", "find", "locat", "investigat", "research", "scan", "survey", "look" },
	planner = { "plan", "architect", "outline", "spec", "strateg", "roadmap", "propos" },
	lookout = { "review", "audit", "verif", "check", "inspect", "monitor", "watch", "validat", "critiqu" },
	builder = { "build", "test", "compil", "fix", "implement", "install", "setup", "ci" },
	coder = { "code", "coding", "edit", "refactor", "renam", "port", "rewrit", "patch" },
	git = { "git", "commit", "branch", "merg", "rebas", "diff", "pr", "pull" },
	server = { "server", "docker", "database", "db", "api", "deploy", "infra", "sql", "backend" },
	diver = { "debug", "trac", "dig", "deep", "root", "profil", "crash", "bug", "ssh" },
	robot = { "agent", "automat", "workflow", "script", "bot", "orchestrat" },
	scientist = { "analy", "experiment", "benchmark", "measur", "data", "metric", "stat" },
	painter = { "design", "ui", "css", "style", "layout", "visual", "icon", "theme", "color", "sprite" },
	musician = { "doc", "readme", "writ", "summar", "explain", "translat", "note", "compos" },
	gardener = { "clean", "prun", "tidy", "remov", "delet", "upgrad", "depend", "migrat" },
	ninja = { "quick", "fast", "small", "simpl", "minor", "tiny" },
	royal = { "lead", "coordinat", "manag", "decid", "approv" },
	cowboy = { "wrangl", "hunt", "chase", "round" },
	wizard = { "generat", "transform", "magic", "convert", "prompt" },
}

--- Outfits a subagent can get at random, in a fixed order.
local subagent_outfits = {}
for outfit in pairs(outfit_words) do
	subagent_outfits[#subagent_outfits + 1] = outfit
end
table.sort(subagent_outfits)

--- A subagent's outfit, from the first word of its type, then its task, that
--- names one; otherwise one picked by the text, so it keeps it every redraw.
function M.subagent_outfit(agent_type, task)
	local text = ((agent_type or "") .. " " .. (task or "")):lower()
	for word in text:gmatch("%a+") do
		local best, length = nil, 0
		for _, outfit in ipairs(subagent_outfits) do
			for _, stem in ipairs(outfit_words[outfit]) do
				local hit
				if #stem > 3 then
					hit = word:sub(1, #stem) == stem
				else
					hit = word == stem or word == stem .. "s" or word == stem .. "es" or word == stem .. "ing"
				end
				if hit and #stem > length then
					best, length = outfit, #stem
				end
			end
		end
		if best then
			return best
		end
	end
	local hash = 0
	for i = 1, #text do
		hash = (hash * 31 + text:byte(i)) % 2147483647
	end
	return subagent_outfits[hash % #subagent_outfits + 1]
end

--- A Codex session's outfit, from its reasoning effort.
function M.codex_outfit(model, effort)
	effort = (effort or ""):lower()
	if effort == "xhigh" or effort == "high" then
		return "scientist"
	elseif effort == "low" or effort == "minimal" then
		return "ninja"
	end
	return "robot"
end

--- An agent session's outfit.
function M.agent_outfit(adapter_id, model, effort)
	if adapter_id ~= "claude" then
		return M.codex_outfit(model, effort)
	end
	return M.claude_outfit(model, effort)
end

--- The process ID of the agent in a pane, if one runs there.
function M.claude_pid(process)
	local _, _, pid = agents.in_process(process)
	return pid
end
M.agent_pid = M.claude_pid

--- The exit code of a pane's last command, or nil.
local function exit_code(process)
	local e = process and process.last_exit
	if type(e) == "number" then
		return e
	elseif type(e) == "table" then
		return e.code or e.status or e.exit_code
	end
end

--- A crab for a pane's foreground program.
function M.pane_crab(process, ages)
	local fg = process.foreground or {}
	local kind, name = M.program_kind(fg.argv0 or fg.name)
	local folder = basename(fg.cwd or "")
	local crab = { kind = kind, outfit = outfit_of_kind[kind], color = M.colors[kind], accent = M.program_accent(name), state = "busy" }
	if kind == "shell" then
		crab.name, crab.state, crab.detail = folder ~= "" and folder or name, "sleep", "zzz"
		local code = exit_code(process)
		if code and code ~= 0 then
			crab.outfit, crab.state, crab.detail = "fire", "busy", "exit " .. code .. "!"
		elseif code == 0 then
			crab.detail = "✓ zzz"
		end
	else
		crab.name, crab.detail = name, folder
		crab.age = ages and fg.pid and ages[fg.pid]
	end
	return crab
end

--- Panes the extensions open for themselves, which aren't work in the tab.
function M.helper_pane(label)
	return label == "Crabs" or label:sub(1, 9) == "Sidecar: " or label:sub(1, 6) == "Diff: " or label:sub(1, 6) == "View: "
end

--- Merges crabs with the same title and description into one, which counts
--- them and keeps the longest uptime. Waiting crabs go last; the rest keep
--- their order.
function M.group(crabs)
	local out, by_key = {}, {}
	for _, crab in ipairs(crabs) do
		local key = table.concat({ crab.name or "", crab.detail or "", crab.outfit or "", crab.state or "" }, "\0")
		local first = by_key[key]
		if first then
			first.count = first.count + 1
			if crab.age and (not first.age or crab.age > first.age) then
				first.age = crab.age
			end
		else
			crab.count = 1
			by_key[key] = crab
			out[#out + 1] = crab
		end
	end
	for _, crab in ipairs(out) do
		if crab.count > 1 then
			crab.name = (crab.name or "") .. " ×" .. crab.count
		end
		if crab.state == "busy" and crab.age and not crab.extra then
			crab.extra = "up " .. M.duration(crab.age)
		end
	end
	local awake, waiting = {}, {}
	for _, crab in ipairs(out) do
		table.insert(crab.state == "sleep" and waiting or awake, crab)
	end
	for _, crab in ipairs(waiting) do
		awake[#awake + 1] = crab
	end
	return awake
end

--- Programs that only carry a Claude task's real one.
local carriers = { zsh = true, bash = true, sh = true, sleep = true, env = true, timeout = true, caffeinate = true }

--- A new record of the monitors a Claude started, from its transcript.
function M.new_monitors()
	return { offset = 0, partial = "", descriptions = {}, list = {} }
end

local function monitor_record(monitors, r)
	local content = r.message and r.message.content
	if type(content) ~= "table" then
		return
	end
	for _, item in ipairs(content) do
		if r.type == "assistant" and item.type == "tool_use" and item.name == "Monitor" then
			monitors.descriptions[item.id] = (type(item.input) == "table" and item.input.description) or "monitor"
		elseif r.type == "user" and item.type == "tool_result" and monitors.descriptions[item.tool_use_id] then
			local result = type(r.toolUseResult) == "table" and r.toolUseResult or {}
			local at = M.iso_time(r.timestamp)
			if at and result.timeoutMs then
				monitors.list[#monitors.list + 1] = {
					description = monitors.descriptions[item.tool_use_id],
					at = at,
					expires = at + result.timeoutMs / 1000,
				}
			end
		end
	end
end

--- Adds a chunk of transcript. Only lines that can name a monitor are decoded;
--- API request records list every tool and are large, so they're skipped.
function M.feed_monitors(monitors, chunk)
	local text = monitors.partial .. chunk
	local pos = 1
	while true do
		local nl = text:find("\n", pos, true)
		if not nl then
			break
		end
		local line = text:sub(pos, nl - 1)
		if (line:find('"Monitor"', 1, true) or line:find('"timeoutMs"', 1, true)) and not line:find('^{"type":"api%-request') then
			local ok, r = pcall(rex.json.decode, line)
			if ok and type(r) == "table" then
				monitor_record(monitors, r)
			end
		end
		pos = nl + 1
	end
	monitors.partial = text:sub(pos)
end

--- The monitor a Claude's shell runs. A process only has its program's name, so
--- it's matched by start time: a monitor starts its shell as it's recorded.
local function monitor_of(wrapper, monitors, used, now)
	local best, closest
	for _, m in ipairs(monitors or {}) do
		if wrapper.age and not used[m] and now <= m.expires then
			local apart = math.abs(now - m.at - wrapper.age)
			if apart <= 10 and (not closest or apart < closest) then
				best, closest = m, apart
			end
		end
	end
	if best then
		used[best] = true
	end
	return best
end

--- Crabs for a Claude's background tasks: the shells it started, each named by
--- the monitor it runs or else by its program, from processes ({ pid, ppid, age,
--- comm }). Only executable names are read, never arguments, which can hold
--- secrets. `monitors` is the list from its transcript, if known.
function M.task_crabs(claude_pid, processes, monitors, now, who)
	who = who or "Claude"
	local used = {}
	local children = {}
	for _, p in ipairs(processes) do
		children[p.ppid] = children[p.ppid] or {}
		table.insert(children[p.ppid], p)
	end
	local crabs = {}
	for _, wrapper in ipairs(children[claude_pid] or {}) do
		local kind = M.program_kind(wrapper.comm)
		if kind == "shell" then
			local names, queue = {}, { wrapper.pid }
			while #queue > 0 do
				local pid = table.remove(queue, 1)
				for _, child in ipairs(children[pid] or {}) do
					names[#names + 1] = basename(child.comm)
					queue[#queue + 1] = child.pid
				end
			end
			local program, sleeps, tails = nil, false, false
			for _, name in ipairs(names) do
				if name == "tail" then
					tails = true
				elseif name == "sleep" then
					sleeps = true
				elseif not program and not carriers[name] then
					program = name
				end
			end
			local crab
			local monitor = monitor_of(wrapper, monitors, used, now or os.time())
			if monitor then
				crab = { kind = "monitor", outfit = "lookout", color = M.colors.monitor, state = "busy", name = monitor.description, detail = who .. "'s monitor" }
			elseif tails then
				crab = { kind = "monitor", outfit = "lookout", color = M.colors.monitor, state = "busy", name = "monitor", detail = "watching output" }
			elseif program then
				local k, name = M.program_kind(program)
				crab = { kind = k, outfit = outfit_of_kind[k], color = M.colors[k], accent = M.program_accent(name), state = "busy", name = name, detail = who .. "'s shell" }
			elseif sleeps then
				crab = { kind = "shell", outfit = "sleeper", color = M.colors.shell, state = "sleep", name = "waiting", detail = who .. "'s shell" }
			else
				crab = { kind = "shell", outfit = "plain", color = M.colors.shell, state = "busy", name = "shell", detail = who .. "'s shell" }
			end
			crab.age = wrapper.age
			crabs[#crabs + 1] = crab
		end
	end
	return crabs
end

-- Drawing -------------------------------------------------------------------

local raw_rgb = agents.util.rgb
local rgb_cache = {}
local function rgb(hex)
	local c = rgb_cache[hex]
	if not c then
		c = raw_rgb(hex)
		rgb_cache[hex] = c
	end
	return c
end

local shade_cache = {}
local function shade(hex, factor)
	local key = tostring(hex) .. "\0" .. tostring(factor)
	local out = shade_cache[key]
	if not out then
		local c = rgb(hex)
		out = string.format("%d;%d;%d", math.floor(c[1] * factor), math.floor(c[2] * factor), math.floor(c[3] * factor))
		shade_cache[key] = out
	end
	return out
end

local function gradient_shade(stops, t, factor)
	t = math.max(0, math.min(1, t))
	local span = #stops - 1
	if span <= 0 then
		return shade(stops[1], factor)
	end
	local pos = t * span
	local i = math.min(span, math.floor(pos) + 1)
	local f = pos - (i - 1)
	local a, b = rgb(stops[i]), rgb(stops[i + 1])
	return string.format(
		"%d;%d;%d",
		math.floor((a[1] + (b[1] - a[1]) * f) * factor + 0.5),
		math.floor((a[2] + (b[2] - a[2]) * f) * factor + 0.5),
		math.floor((a[3] + (b[3] - a[3]) * f) * factor + 0.5)
	)
end

local grad_col_cache = setmetatable({}, { __mode = "k" })
local function gradient_cols(stops, factor)
	local by_f = grad_col_cache[stops]
	if not by_f then
		by_f = {}
		grad_col_cache[stops] = by_f
	end
	local cols = by_f[factor]
	if not cols then
		cols = {}
		for cx = 0, 6 do
			cols[cx] = gradient_shade(stops, cx / 5, factor)
		end
		by_f[factor] = cols
	end
	return cols
end

--- A canvas of cols x rows cells, each 2 x 4 pixels, with text on top.
function M.canvas(cols, rows)
	return { cols = cols, rows = rows, width = cols * 2, height = rows * 4, px = {}, text = {}, row_max = {} }
end

--- A crab's width in cells.
M.crab_cols = math.ceil(sprites.width / 2)

local function plot(c, x, y, color)
	if x >= 0 and x < c.width and y >= 0 and y < c.height then
		c.px[y * c.width + x + 1] = color
		local row = math.floor(y / 4)
		local col = math.floor(x / 2)
		local rm = c.row_max
		if rm then
			local prev = rm[row]
			if not prev or col > prev then
				rm[row] = col
			end
		end
	end
end

--- Writes segments ({ text, color, bold, gradient }) from a column, up to width cells.
function M.write(c, col, row, segments, width)
	if row < 0 or row >= c.rows then
		return
	end
	local limit = math.min(c.cols, col + width)
	local rm = c.row_max
	for _, seg in ipairs(segments) do
		local s = M.clip(seg[1], limit - col)
		local grad = seg[4]
		local span = grad and math.max(1, M.width(s) - 1) or 1
		local solid = not grad and shade(seg[2] or M.colors.text, 1) or nil
		local idx = 0
		for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
			local color = solid or gradient_shade(grad, idx / span, 1)
			c.text[row * c.cols + col + 1] = { ch, color, seg[3] }
			if rm then
				local prev = rm[row]
				if not prev or col > prev then
					rm[row] = col
				end
			end
			col = col + 1
			idx = idx + 1
		end
		if col >= limit then
			return
		end
	end
end

local row_map_cache = {}
--- Where each of a crab's pixel rows lands in a pane height pixels tall, and
--- how many rows the crab keeps.
function M.row_map(height)
	local cached = row_map_cache[height]
	if cached then
		return cached[1], cached[2]
	end
	local sheet = sprites
	local dropped = {}
	for i = 1, math.max(0, sheet.height - height) do
		if sheet.drop_order[i] then
			dropped[sheet.drop_order[i]] = true
		end
	end
	local map, kept = {}, 0
	for y = 0, sheet.height - 1 do
		if not dropped[y] then
			map[y] = kept
			kept = kept + 1
		end
	end
	row_map_cache[height] = { map, kept }
	return map, kept
end

--- Draws a crab with its left edge at cell column col and its kept pixel
--- rows starting at pixel row oy. Busy crabs bob, step and wave; idle ones
--- blink and fade; sleeping ones keep their eyes shut.
function M.draw_crab(c, col, oy, crab, frame, map)
	local sheet = sprites
	local ox = col * 2
	map = map or M.row_map(sheet.height)
	local function put(x, y, color, shift)
		local my = map[y]
		if my then
			plot(c, ox + x, oy + my + (shift or 0), color)
		end
	end
	local busy = crab.state == "busy"
	local factor = busy and 1 or 0.6
	local body = crab.color or M.colors.claude
	local grad = crab.gradient
	local solid_body = not grad and shade(body, factor) or nil
	local gcols = grad and gradient_cols(grad, factor) or nil
	-- Quantise gradients per 2-pixel cell column so octant cells keep one body colour.
	local function body_at(x)
		if gcols then
			return gcols[math.floor(x / 2)] or gcols[5]
		end
		return solid_body
	end
	local bob = (busy and (frame % 4 == 1 or frame % 4 == 2)) and -1 or 0
	local lifted = busy and (frame % 2 + 1) or 0
	local bottom = sheet.height - 1
	for pair, columns in ipairs(sheet.legs) do
		for _, x in ipairs(columns) do
			local leg = body_at(x)
			for y = pair == lifted and sheet.leg_top + 1 or sheet.leg_top, bottom do
				put(x, y, leg)
			end
			if bob < 0 then
				put(x, sheet.leg_top, leg, -1)
			end
		end
	end
	local shut = crab.state == "sleep" or (not busy and frame % 20 == 0)
	local eye_open = shade(sheet.eye, 1)
	local shut_cols = shut and (grad and gradient_cols(grad, factor * 0.7) or nil) or nil
	local shut_solid = shut and (not grad and shade(body, factor * 0.7) or nil) or nil
	for dy, line in ipairs(sheet.body.rows) do
		local py = sheet.body.y + dy - 1
		for dx = 1, #line do
			local ch = line:sub(dx, dx)
			if ch == "c" then
				put(dx - 1, py, body_at(dx - 1), bob)
			elseif ch == "k" then
				local ec = eye_open
				if shut then
					ec = shut_cols and (shut_cols[math.floor((dx - 1) / 2)] or shut_cols[5]) or shut_solid
				end
				put(dx - 1, py, ec, bob)
			end
		end
	end
	local wave = busy and frame % 2 or -1
	local arms = sheet.arms
	for side = 1, 2 do
		local x = side == 1 and arms.left or arms.right
		local up = (side == 1 and wave == 0) or (side == 2 and wave == 1)
		local shift = bob - (up and 1 or 0)
		for dx = 0, arms.size - 1 do
			local col_c = body_at(x + dx)
			for dy = 0, arms.size - 1 do
				put(x + dx, arms.y + dy, col_c, shift)
			end
		end
	end
	for _, part in ipairs(sheet.outfits[crab.outfit or "plain"] or {}) do
		local rows = part.rows
		if part.frames then
			local speed = busy and 2 or 4
			rows = part.frames[math.floor(frame / speed) % #part.frames + 1]
		end
		local shift = part.fixed and 0 or bob
		for dy, line in ipairs(rows) do
			local py = part.y + dy - 1
			for dx = 1, #line do
				local hex = part.legend[line:sub(dx, dx)]
				if hex == "body" then
					put(part.x + dx - 1, py, body_at(part.x + dx - 1), shift)
				elseif hex then
					if hex == "accent" then
						hex = crab.accent or part.accent
					end
					if hex then
						put(part.x + dx - 1, py, shade(hex, factor), shift)
					end
				end
			end
		end
	end
	if crab.state == "sleep" then
		local drift = math.floor(frame % 8 / 4)
		local row = math.floor(oy / 4) - drift
		M.write(c, col + M.crab_cols - 1 + drift, math.max(0, row), { { drift == 0 and "z" or "Z", M.colors.dim } }, 1)
	end
end

--- The terminal text for a canvas: each cell draws its 2 x 4 pixels as one
--- octant character in its two most common colours, the rest taking the
--- nearer of those two; text goes on top. Rows are joined one at a time, as
--- this Lua can't join a whole screen's worth of pieces at once.
function M.render(c)
	local lines, sgr = {}, nil
	local w = c.width
	local px, text, rm = c.px, c.text, c.row_max
	local use_rm = rm ~= nil and (next(rm) ~= nil or (next(px) == nil and next(text) == nil))
	for row = 0, c.rows - 1 do
		local last_col = use_rm and rm[row] or (c.cols - 1)
		if not last_col then
			if sgr ~= "" then
				lines[#lines + 1] = "\27[0m\27[K"
				sgr = ""
			else
				lines[#lines + 1] = "\27[K"
			end
		else
			local out, on = {}, 0
			local function set(code)
				if code ~= sgr then
					on = on + 1
					out[on] = "\27[0m" .. code
					sgr = code
				end
			end
			local text_row = row * c.cols + 1
			local r0 = row * 4 * w + 1
			local r1 = r0 + w
			local r2 = r1 + w
			local r3 = r2 + w
			for col = 0, last_col do
				local t = text[text_row + col]
				if t then
					set("\27[38;2;" .. t[2] .. "m" .. (t[3] and "\27[1m" or ""))
					on = on + 1
					out[on] = t[1]
				else
					local x2 = col * 2
					local p0 = px[r0 + x2]
					local p1 = px[r0 + x2 + 1]
					local p2 = px[r1 + x2]
					local p3 = px[r1 + x2 + 1]
					local p4 = px[r2 + x2]
					local p5 = px[r2 + x2 + 1]
					local p6 = px[r3 + x2]
					local p7 = px[r3 + x2 + 1]
					local fg = p0 or p1 or p2 or p3 or p4 or p5 or p6 or p7
					if not fg then
						set("")
						on = on + 1
						out[on] = " "
					elseif (not p0 or p0 == fg) and (not p1 or p1 == fg)
						and (not p2 or p2 == fg) and (not p3 or p3 == fg)
						and (not p4 or p4 == fg) and (not p5 or p5 == fg)
						and (not p6 or p6 == fg) and (not p7 or p7 == fg) then
						local mask = (p0 and 1 or 0) + (p1 and 2 or 0) + (p2 and 4 or 0) + (p3 and 8 or 0)
							+ (p4 and 16 or 0) + (p5 and 32 or 0) + (p6 and 64 or 0) + (p7 and 128 or 0)
						set("\27[38;2;" .. fg .. "m")
						on = on + 1
						out[on] = glyphs[mask + 1]
					else
						local counts, empty = {}, 0
						local function tally(p)
							if p then
								counts[p] = (counts[p] or 0) + 1
							else
								empty = empty + 1
							end
						end
						tally(p0); tally(p1); tally(p2); tally(p3)
						tally(p4); tally(p5); tally(p6); tally(p7)
						local fgn, bg, bgn = 0, nil, 0
						fg = nil
						for color, n in pairs(counts) do
							if n > fgn or (n == fgn and color < fg) then
								bg, bgn, fg, fgn = fg, fgn, color, n
							elseif n > bgn or (n == bgn and (bg == nil or color < bg)) then
								bg, bgn = color, n
							end
						end
						-- The terminal's background counts as a colour too, and wins a
						-- tie, so a crab's edge doesn't take a neighbour's colour.
						if empty >= bgn then
							bg = nil
						end
						local mask = (p0 == fg and 1 or 0) + (p1 == fg and 2 or 0)
							+ (p2 == fg and 4 or 0) + (p3 == fg and 8 or 0)
							+ (p4 == fg and 16 or 0) + (p5 == fg and 32 or 0)
							+ (p6 == fg and 64 or 0) + (p7 == fg and 128 or 0)
						set("\27[38;2;" .. fg .. (bg and (";48;2;" .. bg) or "") .. "m")
						on = on + 1
						out[on] = glyphs[mask + 1]
					end
				end
			end
			set("")
			on = on + 1
			out[on] = "\27[K"
			lines[#lines + 1] = table.concat(out)
		end
	end
	return "\27[H" .. table.concat(lines, "\r\n")
end

local tile_label = 16
local main_label = 32

--- Lays out the pond, left to right: the main crab with its name, model and uptime, then the other crabs. They
--- wrap onto more rows of crabs as the pane has room, the rows sitting at the
--- bottom of the pane, above a blank row if there's room for one; when they still don't fit, the last place shows a
--- plain crab counting the rest.
function M.scene(cols, rows, view, frame, now)
	local c = M.canvas(cols, rows)
	local map, kept = M.row_map(math.min(rows, 3) * 4)
	local lines = math.max(1, math.floor((rows + 1) / 4))
	local x = 0

	local main = view.main
	local main_lines, main_width = nil, 0
	if main then
		main_lines = {
			{ { main.name or "Claude", main.color or M.colors.claude, true, main.gradient } },
			{ { main.detail or "", M.colors.text } },
			{ { main.extra or "", M.colors.dim } },
		}
		for _, line in ipairs(main_lines) do
			main_width = math.max(main_width, math.min(main_label, M.width(line[1][1])))
		end
		x = x + M.crab_cols + 1 + main_width + 3
	end

	-- Where the other crabs go: after the main crab on the first row, then
	-- from the left on the rows below.
	local crabs = view.crabs or {}
	local need = M.crab_cols + 1 + tile_label
	local tile = need + 2
	local slots = {}
	for line = 0, lines - 1 do
		local sx = line == 0 and x or 0
		-- A crab goes on a row only with room for its label, except at the
		-- start of a row in a pane too narrow for one.
		while sx + need <= cols or (sx == 0 and sx + M.crab_cols <= cols) do
			slots[#slots + 1] = { x = sx, line = line }
			sx = sx + tile
			if sx + need > cols then
				break
			end
		end
	end
	if #crabs > #slots and #slots > 0 then
		local kept_crabs = {}
		for i = 1, #slots - 1 do
			kept_crabs[i] = crabs[i]
		end
		kept_crabs[#slots] = {
			outfit = "plain",
			state = "idle",
			color = M.colors.shell,
			name = "+" .. (#crabs - #slots + 1),
			detail = "more crabs",
		}
		crabs = kept_crabs
	end
	local shown = math.min(#crabs, #slots)
	local used = 1
	if shown > 0 then
		used = slots[shown].line + 1
	end
	-- Rex pads above the text and not below it, so a spare row goes underneath.
	local base = math.max(0, rows - (used * 4 - 1) - 1)
	local function top(line)
		return base + line * 4
	end
	local function oy(line)
		return top(line) * 4 + math.min(rows, 3) * 4 - kept
	end

	if main then
		M.draw_crab(c, 0, oy(0), main, frame, map)
		for i, line in ipairs(main_lines) do
			M.write(c, M.crab_cols + 1, top(0) + i - 1, line, main_width)
		end
	end
	for n = 1, shown do
		local crab, slot = crabs[n], slots[n]
		M.draw_crab(c, slot.x, oy(slot.line), crab, frame + n, map)
		local lx, row = slot.x + M.crab_cols + 1, top(slot.line)
		M.write(c, lx, row, { { crab.name or "?", crab.color, true, crab.gradient } }, tile_label)
		M.write(c, lx, row + 1, { { crab.detail or "", M.colors.dim } }, tile_label)
		if crab.extra then
			M.write(c, lx, row + 2, { { crab.extra, M.colors.dim } }, tile_label)
		end
	end
	return c
end

-- Gathering -----------------------------------------------------------------

local function list(command)
	local r = rex.exec(command, { timeout = 5 })
	local out = {}
	if r and r.ok then
		for line in r.stdout:gmatch("[^\n]+") do
			out[#out + 1] = line
		end
	end
	return out
end

local function call(method, params)
	local ok, result = pcall(rex.call, method, params)
	return ok and result or nil
end

local function block_call(session_id, block_id, method)
	local ok, result = pcall(rex.block.call, terminal, method, { session_id = session_id, block_id = block_id })
	return ok and result or nil
end

local pond = {
	session_id = agents.session_of(os.getenv("REX_BLOCK")),
	block_id = os.getenv("REX_BLOCK"),
	frame = 0,
	gathered = 0,
	cols = 80,
	rows = 6,
	drawn = nil,
	last_out = nil,
	visible = true,
	dirty = true,
	main_pid = nil,
	view = {},
	--- Transcript path -> what's been read of its monitors.
	monitors = {},
}

--- Whether any crab in the current view animates continuously (busy or sleeping).
local function has_motion(view)
	local m = view and view.main
	if m and (m.state == "busy" or m.state == "sleep") then
		return true
	end
	for _, crab in ipairs((view and view.crabs) or {}) do
		if crab.state == "busy" or crab.state == "sleep" then
			return true
		end
	end
	return false
end

--- Whether an idle-only view is entering or leaving a crab blink on this frame.
local function has_blink(view, frame)
	if view and view.main and (frame % 20 == 0 or (frame - 1) % 20 == 0) then
		return true
	end
	for n = 1, #((view and view.crabs) or {}) do
		local f = frame + n
		if f % 20 == 0 or (f - 1) % 20 == 0 then
			return true
		end
	end
	return false
end

--- An agent pane's crab, from its session and adapter theme.
local function agent_crab(adapter, sess, record, now)
	sess = sess or {}
	local theme = agents.theme(adapter)
	local working = (record and record.state == "working") or sess.working
	return {
		kind = adapter.id,
		color = theme.accent or M.colors.agent,
		gradient = theme.gradient,
		outfit = M.agent_outfit(adapter.id, sess.model, sess.effort),
		state = working and "busy" or "idle",
		name = sess.name or adapter.name,
		detail = sess.model_label or adapter.name,
		extra = sess.started and ("up " .. M.duration(now - sess.started)),
	}
end

--- The running subagents of a Claude, named by the tasks it gave them.
--- When a subagent started: the first timestamp in its transcript.
local function started(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local head = f:read(65536) or ""
	f:close()
	return M.iso_time(head:match('"timestamp":"([^"]+)"'))
end

--- The monitors in a transcript, read from where the last read stopped.
local function read_monitors(path)
	if not path then
		return nil
	end
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local monitors = pond.monitors[path]
	local size = f:seek("end")
	if not monitors or size < monitors.offset then
		monitors = M.new_monitors()
		pond.monitors[path] = monitors
	end
	f:seek("set", monitors.offset)
	while true do
		local chunk = f:read(1048576)
		if not chunk then
			break
		end
		monitors.offset = monitors.offset + #chunk
		M.feed_monitors(monitors, chunk)
	end
	f:close()
	return monitors.list
end

--- Crabs for an agent's running subagents, named by the tasks it gave them.
local function subagent_crabs(adapter, sess, into, now)
	if not sess then
		return
	end
	local theme = agents.theme(adapter)
	for _, sub in ipairs(adapter.subagents(sess, now)) do
		if sub.running then
			local since = sub.started or (sub.transcript and started(sub.transcript))
			into[#into + 1] = {
				age = since and (now - since),
				kind = "subagent",
				color = theme.agent or theme.accent or M.colors.subagent,
				outfit = M.subagent_outfit(sub.type, sub.description),
				state = "busy",
				name = sub.description or sub.type or "agent",
				detail = sub.type,
			}
		end
	end
end

local function gather()
	local now = os.time()
	local view = call("session.view", { session_id = pond.session_id })
	local tab
	for _, w in ipairs(view and view.windows or {}) do
		for _, layer in ipairs(w.layers or {}) do
			for _, b in ipairs(layer.blocks or {}) do
				if b.block_id == pond.block_id then
					tab = w
				end
			end
		end
	end
	if not tab then
		return
	end
	-- Skip heavy polling and rendering while this pond lives in a background tab.
	local visible = (not view.active_window_id) or (tab.window_id == view.active_window_id)
	pond.visible = visible
	if not visible then
		return
	end

	local size = block_call(pond.session_id, pond.block_id, "size")
	if size and size.columns then
		pond.cols, pond.rows = size.columns, size.rows
	end

	local processes, ages = {}, {}
	for _, line in ipairs(list({ "/bin/ps", "-axo", "pid=,ppid=,etime=,comm=" })) do
		local pid, ppid, etime, comm = line:match("^%s*(%d+)%s+(%d+)%s+(%S+)%s+(.+)$")
		if pid then
			local p = { pid = tonumber(pid), ppid = tonumber(ppid), age = M.etime(etime), comm = comm }
			processes[#processes + 1] = p
			ages[p.pid] = p.age
		end
	end

	-- The tab's panes: Claudes, and crabs for the rest.
	local claudes, shells = {}, {}
	for _, layer in ipairs(tab.layers or {}) do
		for _, b in ipairs(layer.blocks or {}) do
			local label = b.label or ""
			if b.creator_name == terminal and not M.helper_pane(label) then
				local p = block_call(pond.session_id, b.block_id, "process")
				local adapter, sess = agents.session(p, pond.session_id, b.block_id)
				local pid = M.claude_pid(p)
				if adapter and pid then
					local status = block_call(pond.session_id, b.block_id, "program_status")
					claudes[#claudes + 1] = {
						block_id = b.block_id,
						pid = pid,
						adapter = adapter,
						sess = sess,
						record = status and status.records and status.records[1],
					}
				elseif p and p.foreground then
					shells[#shells + 1] = M.pane_crab(p, ages)
				end
			end
		end
	end

	-- The main Claude: the focused one, else the last one in front.
	local main_index
	for i, cl in ipairs(claudes) do
		if cl.block_id == tab.focused_block_id then
			main_index = i
		end
	end
	if not main_index then
		for i, cl in ipairs(claudes) do
			if cl.pid == pond.main_pid then
				main_index = i
			end
		end
	end
	main_index = main_index or (#claudes > 0 and 1 or nil)

	local result, crabs, others = { crabs = {} }, {}, {}
	for i, cl in ipairs(claudes) do
		local crab = agent_crab(cl.adapter, cl.sess, cl.record, now)
		if i == main_index then
			result.main = crab
			pond.main_pid = cl.pid
		else
			others[#others + 1] = crab
		end
		subagent_crabs(cl.adapter, cl.sess, crabs, now)
		-- Monitors are Claude Code's; a Codex runs its commands under its
		-- app-server, so none are this pane's children.
		local monitors = cl.adapter.id == "claude" and cl.sess and read_monitors(cl.sess.transcript) or nil
		for _, task in ipairs(M.task_crabs(cl.pid, processes, monitors, now, cl.adapter.name)) do
			crabs[#crabs + 1] = task
		end
	end
	for _, crab in ipairs(others) do
		crabs[#crabs + 1] = crab
	end
	table.sort(shells, function(a, b)
		return (a.state == "busy") and not (b.state == "busy")
	end)
	for _, crab in ipairs(shells) do
		crabs[#crabs + 1] = crab
	end
	result.crabs = M.group(crabs)
	pond.view = result
	pond.dirty = true
end

local function tick()
	local now = os.time()
	local ok, err = pcall(function()
		local motion = has_motion(pond.view)
		local gather_every = not pond.visible and 1 or (motion and 2 or 4)
		if now - pond.gathered >= gather_every then
			pond.gathered = now
			gather()
			motion = has_motion(pond.view)
		end
		if not pond.visible then
			return
		end
		local size = pond.cols .. "x" .. pond.rows
		if size ~= pond.drawn then
			pond.drawn = size
			pond.last_out = nil
			pond.dirty = true
			io.write("\27[2J")
		end
		if pond.dirty or motion or has_blink(pond.view, pond.frame) then
			pond.dirty = false
			local rendered = M.render(M.scene(pond.cols, pond.rows, pond.view, pond.frame, now))
			if rendered ~= pond.last_out then
				pond.last_out = rendered
				io.write(rendered)
				if io.stdout.flush then
					io.stdout:flush()
				end
			end
		end
	end)
	if not ok then
		io.write("\27[H\27[2J" .. tostring(err))
	end
	pond.frame = pond.frame + 1
	rex.after(pond.visible and 0.25 or 1.0, tick)
end

if REX_CRAB_POND_TEST then
	return M
end

io.write("\27[?25l\27[2J")
-- A handler keeps the script running between ticks.
rex.on("block_closed", function() end)
rex.after(0.1, tick)
