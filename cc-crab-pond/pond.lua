-- The crab pond: runs inside the "Crabs" pane that watcher.lua opens, and
-- draws what runs in this tab as pixel crabs: the Claude usage limits, then
-- the tab's main Claude, then crabs for its subagents and background tasks,
-- the tab's other Claudes and the programs in its other panes. It reads
-- Claude Code's session and status line files, Rex's view of the tab and the
-- process list, and gathers them again every 2 seconds; the crabs move 4
-- times a second.

local dir = debug.getinfo(1, "S").source:match("^@?(.*/)")
local sprites = dofile(dir .. "sprites.lua")
local glyphs = dofile(dir .. "glyphs.lua")

local M = {}

local terminal = "com.superlogical.terminal"
local home = os.getenv("HOME") or ""
local claude_dir = home .. "/.claude"

M.colors = {
	claude = "#D97757",
	subagent = "#E89A7F",
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
	agent = { "codex", "gemini", "aider", "opencode", "cursor-agent", "amp", "goose", "crush", "qwen" },
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

function M.gauge(percent, cells)
	local filled = math.max(0, math.min(cells, math.floor(percent / 100 * cells + 0.5)))
	return string.rep("▓", filled) .. string.rep("░", cells - filled)
end

-- Who is who --------------------------------------------------------------

--- The kind of crab for a program, and its plain name.
function M.program_kind(argv0)
	local name = basename(argv0):gsub("^%-", "")
	return kind_of_program[name] or "other", name
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

local function is_claude(p)
	return p ~= nil and p.argv0 ~= nil and basename(p.argv0) == "claude"
end

--- The process ID of the Claude in a pane, if one runs there.
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
	local crab = { kind = kind, outfit = outfit_of_kind[kind], color = M.colors[kind], state = "busy" }
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

--- Crabs for a Claude's background tasks: the shells it started, each named
--- by the program it runs, from processes ({ pid, ppid, age, comm }). Only
--- executable names are read, never arguments, which can hold secrets.
function M.task_crabs(claude_pid, processes)
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
			if tails then
				crab = { kind = "monitor", outfit = "lookout", color = M.colors.monitor, state = "busy", name = "monitor", detail = "watching output" }
			elseif program then
				local k, name = M.program_kind(program)
				crab = { kind = k, outfit = outfit_of_kind[k], color = M.colors[k], state = "busy", name = name, detail = "Claude's shell" }
			elseif sleeps then
				crab = { kind = "shell", outfit = "sleeper", color = M.colors.shell, state = "sleep", name = "waiting", detail = "Claude's shell" }
			else
				crab = { kind = "shell", outfit = "plain", color = M.colors.shell, state = "busy", name = "shell", detail = "Claude's shell" }
			end
			crab.age = wrapper.age
			crabs[#crabs + 1] = crab
		end
	end
	return crabs
end

-- Drawing -------------------------------------------------------------------

local function rgb(hex)
	local r, g, b = hex:match("#?(%x%x)(%x%x)(%x%x)")
	return { tonumber(r, 16), tonumber(g, 16), tonumber(b, 16) }
end

local function shade(hex, factor)
	local c = rgb(hex)
	return string.format("%d;%d;%d", math.floor(c[1] * factor), math.floor(c[2] * factor), math.floor(c[3] * factor))
end

--- A canvas of cols x rows cells, each 2 x 4 pixels, with text on top.
function M.canvas(cols, rows)
	return { cols = cols, rows = rows, width = cols * 2, height = rows * 4, px = {}, text = {} }
end

--- A crab's width in cells.
M.crab_cols = math.ceil(sprites.width / 2)

local function plot(c, x, y, color)
	if x >= 0 and x < c.width and y >= 0 and y < c.height then
		c.px[y * c.width + x + 1] = color
	end
end

--- Writes segments ({ text, color, bold }) from a column, up to width cells.
function M.write(c, col, row, segments, width)
	if row < 0 or row >= c.rows then
		return
	end
	local limit = math.min(c.cols, col + width)
	for _, seg in ipairs(segments) do
		local s = M.clip(seg[1], limit - col)
		for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
			c.text[row * c.cols + col + 1] = { ch, shade(seg[2] or M.colors.text, 1), seg[3] }
			col = col + 1
		end
		if col >= limit then
			return
		end
	end
end

--- Where each of a crab's pixel rows lands in a pane height pixels tall, and
--- how many rows the crab keeps.
function M.row_map(height)
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
		if map[y] then
			plot(c, ox + x, oy + map[y] + (shift or 0), color)
		end
	end
	local busy = crab.state == "busy"
	local factor = busy and 1 or 0.6
	local body = crab.color or M.colors.claude
	local bob = (busy and (frame % 4 == 1 or frame % 4 == 2)) and -1 or 0
	local lifted = busy and (frame % 2 + 1) or 0
	local leg = shade(body, factor)
	local bottom = sheet.height - 1
	for pair, columns in ipairs(sheet.legs) do
		for _, x in ipairs(columns) do
			for y = pair == lifted and sheet.leg_top + 1 or sheet.leg_top, bottom do
				put(x, y, leg)
			end
			if bob < 0 then
				put(x, sheet.leg_top, leg, -1)
			end
		end
	end
	local shut = crab.state == "sleep" or (not busy and frame % 20 == 0)
	local eye = shut and shade(body, factor * 0.7) or shade(sheet.eye, 1)
	for dy, line in ipairs(sheet.body.rows) do
		for dx = 1, #line do
			local ch = line:sub(dx, dx)
			if ch == "c" then
				put(dx - 1, sheet.body.y + dy - 1, shade(body, factor), bob)
			elseif ch == "k" then
				put(dx - 1, sheet.body.y + dy - 1, eye, bob)
			end
		end
	end
	local wave = busy and frame % 2 or -1
	local arms = sheet.arms
	for side, x in pairs({ left = arms.left, right = arms.right }) do
		local up = (side == "left" and wave == 0) or (side == "right" and wave == 1)
		for dx = 0, arms.size - 1 do
			for dy = 0, arms.size - 1 do
				put(x + dx, arms.y + dy, shade(body, factor), bob - (up and 1 or 0))
			end
		end
	end
	for _, part in ipairs(sheet.outfits[crab.outfit or "plain"] or {}) do
		local rows = part.rows
		if part.frames then
			local speed = busy and 2 or 4
			rows = part.frames[math.floor(frame / speed) % #part.frames + 1]
		end
		for dy, line in ipairs(rows) do
			for dx = 1, #line do
				local hex = part.legend[line:sub(dx, dx)]
				hex = hex == "body" and body or hex
				if hex then
					put(part.x + dx - 1, part.y + dy - 1, shade(hex, factor), part.fixed and 0 or bob)
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
	for row = 0, c.rows - 1 do
		local out = {}
		local function set(code)
			if code ~= sgr then
				out[#out + 1] = "\27[0m" .. code
				sgr = code
			end
		end
		for col = 0, c.cols - 1 do
			local t = c.text[row * c.cols + col + 1]
			if t then
				set("\27[38;2;" .. t[2] .. "m" .. (t[3] and "\27[1m" or ""))
				out[#out + 1] = t[1]
			else
				local cell, counts, empty = {}, {}, 0
				for n = 0, 7 do
					local p = c.px[(row * 4 + math.floor(n / 2)) * w + col * 2 + n % 2 + 1]
					cell[n] = p
					if p then
						counts[p] = (counts[p] or 0) + 1
					else
						empty = empty + 1
					end
				end
				local fg, fgn, bg, bgn = nil, 0, nil, 0
				for color, n in pairs(counts) do
					if n > fgn or (n == fgn and color < fg) then
						bg, bgn, fg, fgn = fg, fgn, color, n
					elseif n > bgn or (n == bgn and (bg == nil or color < bg)) then
						bg, bgn = color, n
					end
				end
				if not fg then
					set("")
					out[#out + 1] = " "
				else
					-- The terminal's background counts as a colour too, and wins a
					-- tie, so a crab's edge doesn't take a neighbour's colour.
					if empty >= bgn then
						bg = nil
					end
					local mask = 0
					for n = 0, 7 do
						if cell[n] == fg then
							mask = mask + 2 ^ n
						end
					end
					set("\27[38;2;" .. fg .. (bg and (";48;2;" .. bg) or "") .. "m")
					out[#out + 1] = glyphs[mask + 1]
				end
			end
		end
		set("")
		out[#out + 1] = "\27[K"
		lines[#lines + 1] = table.concat(out)
	end
	return "\27[H" .. table.concat(lines, "\r\n")
end

local tile_label = 16
local main_label = 32

--- One limit as text segments: `5h ▓▓▓░░░ 45% ↺14m`.
local function limit_line(l)
	local color = l.percent >= 90 and M.colors.bad or l.percent >= 70 and M.colors.build or M.colors.busy
	return {
		{ l.label .. " ", M.colors.dim },
		{ M.gauge(l.percent, 6), color },
		{ string.format(" %d%%", l.percent), M.colors.text },
		{ l.reset and (" ↺" .. M.duration(l.reset)) or "", M.colors.dim },
	}
end

--- Lays out the pond, left to right: the usage limits one under the other,
--- the main crab with its name, model and uptime, then the other crabs. They
--- wrap onto more rows of crabs as the pane has room, the rows sitting at the
--- bottom of the pane; when they still don't fit, the last place shows a
--- plain crab counting the rest.
function M.scene(cols, rows, view, frame, now)
	local c = M.canvas(cols, rows)
	local map, kept = M.row_map(math.min(rows, 3) * 4)
	local lines = math.max(1, math.floor((rows + 1) / 4))
	local x = 0

	local limits_width = 0
	for _, l in ipairs(view.limits or {}) do
		local w = 0
		for _, seg in ipairs(limit_line(l)) do
			w = w + M.width(seg[1])
		end
		limits_width = math.max(limits_width, w)
	end
	if limits_width > 0 then
		x = limits_width + 3
	end
	local main = view.main
	local main_lines, main_width = nil, 0
	if main then
		main_lines = {
			{ { main.name or "Claude", M.colors.claude, true } },
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
	local base = math.max(0, rows - (used * 4 - 1))
	local function top(line)
		return base + line * 4
	end
	local function oy(line)
		return top(line) * 4 + math.min(rows, 3) * 4 - kept
	end

	-- The limits sit a row apart, so their gauges don't run together.
	for i, l in ipairs(view.limits or {}) do
		M.write(c, 0, math.min(rows - 1, top(0) + (i - 1) * 2), limit_line(l), cols)
	end
	if main then
		local mx = limits_width > 0 and limits_width + 3 or 0
		M.draw_crab(c, mx, oy(0), main, frame, map)
		for i, line in ipairs(main_lines) do
			M.write(c, mx + M.crab_cols + 1, top(0) + i - 1, line, main_width)
		end
	end
	for n = 1, shown do
		local crab, slot = crabs[n], slots[n]
		M.draw_crab(c, slot.x, oy(slot.line), crab, frame + n, map)
		local lx, row = slot.x + M.crab_cols + 1, top(slot.line)
		M.write(c, lx, row, { { crab.name or "?", crab.color, true } }, tile_label)
		M.write(c, lx, row + 1, { { crab.detail or "", M.colors.dim } }, tile_label)
		if crab.extra then
			M.write(c, lx, row + 2, { { crab.extra, M.colors.dim } }, tile_label)
		end
	end
	return c
end

-- Gathering -----------------------------------------------------------------

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
	session_id = os.getenv("REX_SESSION"),
	block_id = os.getenv("REX_BLOCK"),
	frame = 0,
	gathered = 0,
	cols = 80,
	rows = 6,
	drawn = nil,
	main_pid = nil,
	view = {},
}

local function limits_of(statusline, now)
	local out = {}
	local rl = statusline and statusline.rate_limits or {}
	for _, w in ipairs({ { "five_hour", "5h" }, { "seven_day", "7d" } }) do
		local l = rl[w[1]]
		if l and l.used_percentage then
			out[#out + 1] = { label = w[2], percent = math.floor(l.used_percentage), reset = l.resets_at and (l.resets_at - now) }
		end
	end
	return out
end

--- A Claude pane's crab, from its session and status line files.
local function claude_crab(pid, record, now)
	local s = read_json(claude_dir .. "/sessions/" .. pid .. ".json") or {}
	local sl = s.sessionId and read_json(claude_dir .. "/state/statusline/" .. s.sessionId .. ".json") or {}
	local working = (record and record.state == "working") or s.status == "busy"
	local model = sl.model and sl.model.display_name
	return {
		kind = "claude",
		color = M.colors.claude,
		outfit = M.claude_outfit(sl.model and sl.model.id or model, sl.effort and sl.effort.level),
		state = working and "busy" or "idle",
		name = sl.session_name or s.name or "Claude",
		detail = model or "Claude",
		extra = s.startedAt and ("up " .. M.duration(now - s.startedAt / 1000)),
		statusline = sl,
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

local function subagent_crabs(statusline, into, now)
	local transcript = statusline.transcript_path
	if not transcript then
		return
	end
	local agents = transcript:gsub("%.jsonl$", "") .. "/subagents"
	-- A subagent stopped by a crash or a resume never gets `finished`, so only
	-- one whose transcript moved in the last 10 minutes counts as running.
	local recent = {}
	for _, path in ipairs(list({ "/usr/bin/find", agents, "-name", "*.jsonl", "-mmin", "-10" })) do
		recent[basename(path)] = true
	end
	for _, name in ipairs(list({ "/bin/ls", agents })) do
		if name:match("%.meta%.json$") and recent[(name:gsub("%.meta%.json$", ".jsonl"))] then
			local meta = read_json(agents .. "/" .. name)
			if meta and not meta.finished then
				local since = started(agents .. "/" .. name:gsub("%.meta%.json$", ".jsonl"))
				into[#into + 1] = {
					age = since and (now - since),
					kind = "subagent",
					color = M.colors.subagent,
					outfit = M.subagent_outfit(meta.agentType, meta.description),
					state = "busy",
					name = meta.description or meta.agentType or "agent",
					detail = meta.agentType,
				}
			end
		end
	end
end

local function gather()
	local now = os.time()
	local size = block_call(pond.session_id, pond.block_id, "size")
	if size and size.columns then
		pond.cols, pond.rows = size.columns, size.rows
	end

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
			if b.creator_name == terminal and label ~= "Crabs" and label:sub(1, 9) ~= "Changes: " then
				local p = block_call(pond.session_id, b.block_id, "process")
				local pid = M.claude_pid(p)
				if pid then
					local status = block_call(pond.session_id, b.block_id, "program_status")
					claudes[#claudes + 1] = { block_id = b.block_id, pid = pid, record = status and status.records and status.records[1] }
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
		local crab = claude_crab(cl.pid, cl.record, now)
		if i == main_index then
			result.main = crab
			result.limits = limits_of(crab.statusline, now)
			pond.main_pid = cl.pid
		else
			others[#others + 1] = crab
		end
		subagent_crabs(crab.statusline, crabs, now)
		for _, task in ipairs(M.task_crabs(cl.pid, processes)) do
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
end

local function tick()
	local now = os.time()
	local ok, err = pcall(function()
		if now - pond.gathered >= 2 then
			pond.gathered = now
			gather()
		end
		local size = pond.cols .. "x" .. pond.rows
		if size ~= pond.drawn then
			pond.drawn = size
			io.write("\27[2J")
		end
		io.write(M.render(M.scene(pond.cols, pond.rows, pond.view, pond.frame, now)))
		if io.stdout.flush then
			io.stdout:flush()
		end
	end)
	if not ok then
		io.write("\27[H\27[2J" .. tostring(err))
	end
	pond.frame = pond.frame + 1
	rex.after(0.25, tick)
end

if CC_CRAB_POND_TEST then
	return M
end

io.write("\27[?25l\27[2J")
-- A handler keeps the script running between ticks.
rex.on("block_closed", function() end)
rex.after(0.1, tick)
