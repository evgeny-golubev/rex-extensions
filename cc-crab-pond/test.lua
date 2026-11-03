-- Run: rex do ~/.config/rex/extensions/cc-crab-pond/test.lua
-- Mocks the Rex API: it doesn't touch live sessions or panes.
local real = rex
local dir = debug.getinfo(1, "S").source:match("^@?(.*/)")

local function equal(actual, expected, what)
	if actual ~= expected then
		error(what .. ": " .. tostring(actual) .. " ~= " .. tostring(expected), 2)
	end
end

local function terminal(id, window, label)
	return {
		block_id = id,
		window_id = window,
		label = label or "shell",
		creator_name = "com.superlogical.terminal",
		placement = "placed",
	}
end

local clients, blocks, processes, splits, closed, handlers, timers, stopped, next_id, resized

local function reset()
	clients, splits, closed, handlers, timers, stopped, next_id, resized = {}, {}, {}, {}, {}, false, 0, {}
	blocks = {
		terminal("block:1", "window:1"),
		terminal("block:2", "window:1"),
		terminal("block:3", "window:2"),
		terminal("block:9", "window:1", "Crabs"),
	}
	processes = {
		["block:1"] = { foreground = { argv0 = "claude", cwd = "/src/app" } },
		["block:2"] = { foreground = { argv0 = "-zsh", cwd = "/src/app" } },
	}
end


-- settings.json in a throwaway folder, never the real one.
local test_base = real.exec({ "mktemp", "-d" }).stdout:gsub("%s+$", "") .. "/"
CC_CRAB_POND_TEST_BASE = test_base
local S = dofile(dir .. "settings.lua")
local poll

local function request_show(block_id)
	S.request_show(test_base, "session:1", block_id)
	poll()
end

local function run()
	local ok, err = pcall(assert(loadfile(dir .. "watcher.lua")))
	if not ok and err ~= "STOP" then
		error(err, 0)
	end
end

local function foreground(block_id, argv0, ancestors)
	handlers["terminal.process_changed"](
		{ session_id = "session:1", block_id = block_id },
		{ foreground = { argv0 = argv0, cwd = "/src/app" }, ancestors = ancestors }
	)
end

local function user_closes(block_id)
	handlers["block_closed"]({ session_id = "session:1" }, { block_id = block_id })
end

local function fire()
	local due = timers
	timers = {}
	for _, fn in ipairs(due) do
		fn()
	end
end

rex = {
	call = function(method, params)
		if method == "client.list" then
			return { clients = clients }
		elseif method == "client.set_label" or method == "session.attach" then
			return {}
		elseif method == "session.list" then
			return { sessions = { { session_id = "session:1" } } }
		elseif method == "session.list_blocks" then
			return { blocks = blocks }
		elseif method == "session.view" then
			return {
				windows = {
					{ window_id = "window:1", layers = { { kind = "tiled", layout = { split = { split_id = "split:root" } } } } },
					{ window_id = "window:2", layers = { { kind = "tiled", layout = { block_id = "block:3" } } } },
				},
			}
		elseif method == "session.new_split" then
			next_id = next_id + 1
			table.insert(splits, params)
			return { block_ids = { "block:crabs" .. next_id } }
		elseif method == "block.close" then
			table.insert(closed, params.block_id)
			return {}
		elseif method == "session.resize_pane" then
			table.insert(resized, params)
			return {}
		end
		error("unexpected call " .. method)
	end,
	block = {
		call = function(_, _, params)
			return processes[params.block_id]
		end,
	},
	on = function(event, fn)
		handlers[event] = fn
	end,
	every = function(_, fn)
		poll = fn
	end,
	after = function(_, fn)
		table.insert(timers, fn)
	end,
	log = function() end,
	json = real.json,
	stop = function()
		stopped = true
		error("STOP", 0)
	end,
}

local ok, err = pcall(function()
	-- At start, closes stale crab panes and opens one along the bottom of a
	-- tab running Claude.
	reset()
	run()
	equal(closed[1], "block:9", "stale pane closed")
	equal(#splits, 1, "panes opened at start")
	local split = splits[1]
	equal(split.anchor_id, "split:root", "anchor spans the tab")
	equal(split.direction, "vertical", "direction")
	equal(split.side, "after", "side")
	equal(split.ratio, 0.912, "ratio")
	equal(split.focus, false, "focus")
	equal(split.layout.block.label, "Crabs", "label")
	equal(split.layout.block.options.command[4], dir .. "pond.lua", "viewer")
	equal(split.layout.block.options.shell, "none", "no shell")
	fire()
	equal(resized[1].before_block_id, "block:1", "resized above")
	equal(resized[1].after_block_id, "block:crabs1", "resized below")
	equal(resized[1].direction, "vertical", "resized direction")
	equal(resized[1].ratio, 0.912, "resized ratio")

	-- Another pane opening or closing in the session puts the crab pane
	-- back to its share, which the app's re-balancing undoes.
	handlers["block_created"]({ session_id = "session:1" }, { block_id = "block:changes" })
	fire()
	equal(#resized, 2, "resized after a pane opened")
	equal(resized[2].after_block_id, "block:crabs1", "crab pane resized after a pane opened")
	equal(resized[2].ratio, 0.912, "ratio after a pane opened")
	user_closes("block:changes")
	fire()
	equal(#resized, 3, "resized after a pane closed")
	handlers["block_created"]({ session_id = "session:2" }, { block_id = "block:other" })
	fire()
	equal(#resized, 3, "resized for another session")

	-- A second Claude in the tab shares the pane, which closes with the last.
	foreground("block:2", "claude")
	equal(#splits, 1, "panes for a second Claude")
	foreground("block:1", "-zsh")
	equal(#closed, 1, "closed while a Claude runs")
	foreground("block:2", "git", { { argv0 = "claude" } })
	equal(#closed, 1, "closed while Claude runs a command")
	foreground("block:2", "-zsh")
	equal(closed[2], "block:crabs1", "closed with the last Claude")

	-- A tab with one pane is anchored on that pane.
	foreground("block:3", "claude")
	equal(splits[2].anchor_id, "block:3", "anchor of a one-pane tab")

	-- A pane the user closes stays closed until the tab has no Claude.
	user_closes("block:crabs2")
	foreground("block:3", "-zsh")
	equal(#closed, 2, "closed a pane that is already gone")
	foreground("block:3", "claude")
	equal(#splits, 3, "pane for the tab's next Claude")
	foreground("block:1", "claude")
	equal(#splits, 4, "pane for window 1")
	user_closes("block:crabs4")
	foreground("block:1", "-zsh")
	foreground("block:1", "claude")
	equal(#splits, 5, "pane in window 1 again")

	-- Closing the Claude pane counts as Claude exiting.
	user_closes("block:1")
	equal(closed[3], "block:crabs5", "closed with the Claude pane")

	-- A pane whose login shell execs Claude is found by the recheck.
	fire()
	processes["block:2"] = { foreground = { argv0 = "claude", cwd = "/src/app" } }
	foreground("block:2", "/bin/zsh")
	equal(#splits, 5, "pane before the recheck")
	fire()
	equal(#splits, 6, "pane after the recheck")

	-- A second copy quits.
	reset()
	clients = { { info = { label = "cc-crab-pond" } } }
	run()
	equal(stopped, true, "second copy stopped")
	equal(#splits, 0, "second copy's panes")

	-- Settings: on until turned off.
	equal(S.auto_show(test_base), true, "on with no settings file")
	S.set_auto_show(test_base, false)
	equal(S.auto_show(test_base), false, "saved off")

	-- Auto-show off: no pane until asked for one.
	reset()
	run()
	equal(#splits, 0, "no pane with auto-show off")
	poll()
	equal(#splits, 0, "no request, no pane")
	request_show("block:1")
	equal(#splits, 1, "shown in the Claude tab")
	equal(io.open(test_base .. "show-request.json"), nil, "request used up")
	request_show("block:2")
	equal(#splits, 1, "the tab already has one")
	foreground("block:1", "-zsh")
	equal(closed[#closed], "block:crabs1", "still closes with the last Claude")

	-- A tab without Claude can have one, and forgets it when it's closed.
	reset()
	run()
	request_show("block:3")
	equal(#splits, 1, "shown in a tab without Claude")
	user_closes("block:crabs1")
	request_show("block:3")
	equal(#splits, 2, "shown again after being closed")
	S.set_auto_show(test_base, true)
end)
rex = real
real.exec({ "rm", "-rf", test_base })
CC_CRAB_POND_TEST_BASE = nil
if not ok then
	error(err, 0)
end

CC_CRAB_POND_TEST = true
local P = dofile(dir .. "pond.lua")
CC_CRAB_POND_TEST = nil

ok, err = pcall(function()
	-- Programs get crabs by what they do.
	equal(P.program_kind("/opt/homebrew/bin/nvim"), "editor", "editor")
	equal(P.program_kind("-zsh"), "shell", "login shell")
	equal(P.program_kind("go"), "build", "build")
	equal(P.program_kind("/Applications/ChatGPT.app/Contents/Resources/codex"), "agent", "agent")
	equal(P.program_kind("weird"), "other", "other")
	equal(P.program_kind("(zsh)"), "shell", "exiting shell")

	-- Claude dresses by model and effort.
	equal(P.claude_outfit("claude-fable-5-1", "high"), "wizard", "fable")
	equal(P.claude_outfit("claude-opus-5-5", "max"), "scientist", "opus max")
	equal(P.claude_outfit("claude-opus-5-5", "medium"), "cowboy", "opus medium")
	equal(P.claude_outfit("claude-opus-5-5", nil), "cowboy", "opus default")
	equal(P.claude_outfit("claude-sonnet-5-5"), "musician", "sonnet")
	equal(P.claude_outfit(nil), "plain", "unknown")
	equal(P.subagent_outfit("Explore"), "explorer", "explore subagent")
	equal(P.subagent_outfit("Plan"), "planner", "plan subagent")
	equal(P.subagent_outfit("general-purpose", "Review the crab pond diff"), "lookout", "first word that names an outfit")
	equal(P.subagent_outfit("general-purpose", "Debugging the watcher"), "diver", "word that starts with one")
	equal(P.subagent_outfit("general-purpose", "Docker setup"), "server", "longest word wins")
	equal(P.subagent_outfit("general-purpose", "Write docs"), "musician", "short word with -s")
	equal(P.subagent_outfit(nil, "digest"), P.subagent_outfit(nil, "digest"), "same outfit every time")
	local outfit = P.subagent_outfit("general-purpose", "Zebra quokka")
	equal(outfit ~= "plain" and outfit ~= "fire" and outfit ~= "sleeper", true, "random outfit, not a state's")

	-- Claude is found in the foreground or under its command.
	equal(P.claude_pid({ foreground = { argv0 = "claude", pid = 7 } }), 7, "claude in front")
	equal(P.claude_pid({ foreground = { argv0 = "git", pid = 8 }, ancestors = { { argv0 = "claude", pid = 7 } } }), 7, "claude behind")
	equal(P.claude_pid({ foreground = { argv0 = "zsh", pid = 8 } }), nil, "no claude")

	-- A shell sleeps, or burns after a failed command.
	local shell = P.pane_crab({ foreground = { argv0 = "-zsh", cwd = "/src/app" } })
	equal(shell.state, "sleep", "idle shell")
	equal(shell.name, "app", "shell name")
	local failed = P.pane_crab({ foreground = { argv0 = "-zsh", cwd = "/src/app" }, last_exit = 2 })
	equal(failed.outfit, "fire", "failed shell")
	equal(failed.detail, "exit 2!", "failed detail")
	local editor = P.pane_crab({ foreground = { argv0 = "nvim", cwd = "/src/app" } })
	equal(editor.outfit, "coder", "editor outfit")
	equal(editor.state, "busy", "editor state")

	-- A crab fits 3 rows whole, and a shorter pane squeezes its body and legs
	-- before its hat.
	local S = dofile(dir .. "sprites.lua")
	local map, kept = P.row_map(12)
	equal(kept, 12, "rows in a 3-row pane")
	equal(P.crab_cols, 7, "crab width in cells")
	map, kept = P.row_map(8)
	equal(map[9], nil, "lower body dropped")
	equal(map[0], nil, "hat tip dropped")
	equal(map[1], 0, "hat kept")
	equal(map[10], 7, "legs kept")

	-- Every outfit draws, busy and asleep.
	for name in pairs(S.outfits) do
		local c = P.canvas(20, 6)
		P.draw_crab(c, 0, 0, { outfit = name, state = "busy" }, 1)
		P.draw_crab(c, 8, 12, { outfit = name, state = "sleep" }, 2)
	end

	-- A cell draws its 2 x 4 pixels in its two most common colours.
	local c = P.canvas(1, 1)
	c.px[1], c.px[2], c.px[3] = "1;1;1", "1;1;1", "2;2;2"
	local out = P.render(c)
	equal(out:find("38;2;1;1;1m", 1, true) ~= nil, true, "main colour")
	equal(out:find("48;2", 1, true), nil, "empty pixels keep the background")
	equal(out:find("\240\159\174\130", 1, true) ~= nil, true, "top quarter glyph")
	for i = 1, 8 do
		c.px[i] = i <= 5 and "1;1;1" or "2;2;2"
	end
	out = P.render(c)
	equal(out:find("38;2;1;1;1;48;2;2;2;2m", 1, true) ~= nil, true, "two colours")

	-- Claude's background shells become crabs named by their programs.
	local ps = {
		{ pid = 10, ppid = 1, comm = "claude" },
		{ pid = 11, ppid = 10, comm = "/bin/zsh" },
		{ pid = 12, ppid = 11, comm = "/bin/bash" },
		{ pid = 13, ppid = 12, comm = "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" },
		{ pid = 14, ppid = 10, comm = "/bin/zsh" },
		{ pid = 15, ppid = 14, comm = "tail" },
		{ pid = 16, ppid = 14, comm = "ugrep" },
		{ pid = 17, ppid = 10, comm = "/bin/zsh" },
		{ pid = 18, ppid = 17, comm = "sleep" },
		{ pid = 19, ppid = 10, comm = "node" },
		{ pid = 20, ppid = 10, comm = "caffeinate" },
	}
	local tasks = P.task_crabs(10, ps)
	equal(#tasks, 3, "tasks, without MCP servers or helpers")
	equal(tasks[1].name, "xcodebuild", "build task")
	equal(tasks[1].outfit, "builder", "build outfit")
	equal(tasks[2].name, "monitor", "monitor")
	equal(tasks[2].outfit, "lookout", "monitor outfit")
	equal(tasks[3].state, "sleep", "waiting shell")

	-- Same crabs group, keeping the longest uptime; busy ones show it.
	ps[4].age, ps[2].age = 30, 90
	ps[#ps + 1] = { pid = 21, ppid = 10, comm = "/bin/zsh", age = 300 }
	ps[#ps + 1] = { pid = 22, ppid = 21, comm = "xcodebuild" }
	ps[#ps + 1] = { pid = 23, ppid = 10, comm = "/bin/zsh" }
	ps[#ps + 1] = { pid = 24, ppid = 23, comm = "sleep" }
	table.insert(ps, 1, { pid = 25, ppid = 10, comm = "/bin/zsh" })
	table.insert(ps, 2, { pid = 26, ppid = 25, comm = "sleep" })
	local grouped = P.group(P.task_crabs(10, ps))
	equal(#grouped, 3, "groups")
	equal(grouped[1].name, "xcodebuild ×2", "build group")
	equal(grouped[1].extra, "up 5m", "longest uptime")
	equal(grouped[2].name, "monitor", "busy crabs before waiting ones")
	equal(grouped[3].name, "waiting ×3", "waiting group last")
	equal(grouped[3].extra, nil, "no uptime while waiting")
	equal(P.etime("01-06:35:19"), 110119, "days in etime")
	equal(P.etime("02:17"), 137, "minutes in etime")
	equal(P.iso_time("1970-01-01T00:01:00.000Z"), 60, "ISO time")

	-- Text helpers.
	equal(P.width("crab🦀é"), 6, "width")
	equal(P.clip("crab-pond", 5), "crab…", "clip")
	equal(P.duration(8040), "2h14m", "duration")

	-- The scene: the big crab with its name, model and
	-- uptime, then pages of small crabs.
	local view = {
		main = { outfit = "cowboy", state = "busy", color = P.colors.claude, name = "demo session", detail = "Opus 5.5", extra = "up 3h51m" },
		crabs = {},
	}
	for i = 1, 12 do
		view.crabs[i] = { name = "crab" .. i, outfit = "plain", state = i % 2 == 0 and "busy" or "sleep", color = P.colors.shell }
	end
	local text = P.render(P.scene(160, 4, view, 3, 0))
	equal(text:gsub("\27%[[%d;]*[mHK]", ""):match("[^\n]*$"):find("%S"), nil, "a spare row stays blank at the bottom")
	equal(text:find("\240\156\180", 1, true) ~= nil, true, "octants drawn")
	local plain = text:gsub("\27%[[%d;]*[mHK]", "")
	equal(plain:find("demo session", 1, true) ~= nil, true, "name shown")
	local line_of = function(pos)
		local _, n = plain:sub(1, pos):gsub("\r\n", "")
		return n
	end
	equal(plain:find("Opus 5.5", 1, true) ~= nil and plain:find("up 3h51m", 1, true) ~= nil, true, "model and uptime")
	equal(plain:find("1/", 1, true), nil, "no page mark")
	local plus = plain:match("%+(%d+)")
	equal(plus ~= nil, true, "+N crab")
	local shown_crabs = select(2, plain:gsub("crab%d+", ""))
	equal(shown_crabs + tonumber(plus), 12, "+N counts the hidden crabs")
	P.render(P.scene(30, 2, { crabs = view.crabs }, 0, 0))

	-- A taller pane wraps the crabs onto more rows instead of paging.
	local tall = P.scene(160, 12, view, 3, 0)
	text = P.render(tall)
	plain = text:gsub("\27%[[%d;]*[mHK]", "")
	equal(plain:find("+", 1, true), nil, "no +N when rows fit")
	equal(plain:find("crab12", 1, true) ~= nil, true, "last crab shown")
	equal(line_of(plain:find("crab12", 1, true)) > line_of(plain:find("crab1", 1, true)), true, "crabs on a lower row")
	equal(line_of(plain:find("demo session", 1, true)), 0, "rows fill the pane, leaving the bottom row blank")

	-- A crab whose label doesn't fit after the main crab starts the next row.
	local two = { main = view.main, crabs = { { name = "second", outfit = "plain", state = "busy", color = P.colors.shell } } }
	plain = P.render(P.scene(36, 8, two, 0, 0)):gsub("\27%[[%d;]*[mHK]", "")
	equal(line_of(plain:find("second", 1, true)), line_of(plain:find("demo session", 1, true)) + 4, "wrapped to the next row")
	local one_line = P.render(P.scene(36, 4, two, 0, 0)):gsub("\27%[[%d;]*[mHK]", "")
	equal(one_line:find("second", 1, true), nil, "no room in a one-row pane")
	equal(one_line:find("+", 1, true), nil, "no +N without room")
	equal(P.render(P.scene(12, 8, { crabs = two.crabs }, 0, 0)):find("sec", 1, true) ~= nil, true, "narrow pane still shows a crab")
end)
if not ok then
	error(err, 0)
end
return "cc-crab-pond: all tests passed"
