-- Opens a "Crabs" pane along the bottom of every tab that runs Claude Code,
-- and closes it when the last Claude in that tab exits. The pane runs
-- pond.lua. init.lua starts this file with every config load
-- (`rex do --all watcher.lua`).

local terminal = "com.superlogical.terminal"
local dir = debug.getinfo(1, "S").source:match("^@?(.*/)")
local home = os.getenv("HOME") or ""
local rex_binary = home
	.. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"

--- Marks this script's server connection, so a second copy started by
--- `rex config reload` sees the first one and quits.
local client_label = "crab-pond"

--- The crab pane's label; claude-resume skips panes with it.
local label = "Crabs"

--- The share of the tab the panes above the crab pane keep.
local above_ratio = 0.92

--- Claude pane block ID -> { session_id, window_id }.
local claude_panes = {}
--- Window ID -> { session_id, claudes = count, crabs = block ID, or false
--- once the user closed it }. A pane the user closes stays closed until the
--- tab has no Claude left.
local tabs = {}
--- Crab pane block ID -> its window ID.
local owners = {}

local function check(value, err)
	if err ~= nil then
		error(err, 0)
	end
	return value
end

local function is_claude(p)
	return p ~= nil and p.argv0 ~= nil and p.argv0:match("[^/]*$") == "claude"
end

--- Whether Claude runs in the pane: in the foreground, or under a command it
--- started in the foreground.
local function runs_claude(foreground, ancestors)
	if is_claude(foreground) then
		return true
	end
	for _, p in ipairs(ancestors or {}) do
		if is_claude(p) then
			return true
		end
	end
	return false
end

local function window_of(session_id, block_id)
	local result = rex.call("session.list_blocks", { session_id = session_id })
	for _, b in ipairs(result and result.blocks or {}) do
		if b.block_id == block_id then
			return b.window_id
		end
	end
end

--- The split or block at the top of a tab's tiled layout, so the crab pane
--- spans the whole tab.
local function tab_root(session_id, window_id)
	local view = rex.call("session.view", { session_id = session_id })
	for _, w in ipairs(view and view.windows or {}) do
		if w.window_id == window_id then
			for _, layer in ipairs(w.layers or {}) do
				if layer.kind == "tiled" and layer.layout then
					local layout = layer.layout
					return layout.split and layout.split.split_id or layout.block_id
				end
			end
		end
	end
end

--- The app re-balances a new split in the tab it shows, so the ratio is set
--- again once it has.
local function keep_ratio(session_id, before, after, direction, ratio)
	rex.after(0.5, function()
		local _, err = rex.call("session.resize_pane", {
			session_id = session_id,
			direction = direction,
			before_block_id = before,
			after_block_id = after,
			ratio = ratio,
		})
		if err ~= nil then
			rex.log("warn", "sizing a pane: " .. err)
		end
	end)
end

local function open(session_id, window_id, claude)
	local anchor = tab_root(session_id, window_id)
	if not anchor then
		return nil
	end
	local result, err = rex.call("session.new_split", {
		session_id = session_id,
		anchor_id = anchor,
		direction = "vertical",
		side = "after",
		ratio = above_ratio,
		focus = false,
		layout = {
			block = {
				flavor = terminal .. ".shell",
				label = label,
				options = {
					command = { rex_binary, "--autostart=false", "do", dir .. "pond.lua" },
					shell = "none",
					cwd = home,
				},
			},
		},
	})
	if err ~= nil then
		rex.log("warn", "opening a crab pane: " .. err)
		return nil
	end
	local crabs = result.block_ids[1]
	owners[crabs] = window_id
	keep_ratio(session_id, claude, crabs, "vertical", above_ratio)
	return crabs
end

--- Puts the crab pane of every tab in a session back to its share, after
--- another pane opened or closed there and the app re-balanced the tab.
local function refit(session_id)
	for window_id, tab in pairs(tabs) do
		if tab.session_id == session_id and tab.crabs then
			for block_id, pane in pairs(claude_panes) do
				if pane.window_id == window_id then
					keep_ratio(session_id, block_id, tab.crabs, "vertical", above_ratio)
					break
				end
			end
		end
	end
end

local function close_crabs(tab)
	if tab.crabs then
		owners[tab.crabs] = nil
		local _, err = rex.call("block.close", { session_id = tab.session_id, block_id = tab.crabs })
		if err ~= nil then
			rex.log("warn", "closing a crab pane: " .. err)
		end
	end
end

local function claude_started(session_id, block_id)
	local window_id = window_of(session_id, block_id)
	if not window_id then
		return
	end
	claude_panes[block_id] = { session_id = session_id, window_id = window_id }
	local tab = tabs[window_id]
	if not tab then
		tab = { session_id = session_id, claudes = 0 }
		tabs[window_id] = tab
	end
	tab.claudes = tab.claudes + 1
	if tab.crabs == nil then
		tab.crabs = open(session_id, window_id, block_id)
	end
end

local function claude_stopped(block_id)
	local pane = claude_panes[block_id]
	claude_panes[block_id] = nil
	local tab = pane and tabs[pane.window_id]
	if not tab then
		return
	end
	tab.claudes = tab.claudes - 1
	if tab.claudes <= 0 then
		close_crabs(tab)
		tabs[pane.window_id] = nil
	end
end

local update

--- A pane started with a command (`rex split -- claude`) reports its login
--- shell, which then execs Claude without another process_changed event, so
--- a pane without Claude is looked at once more a second later.
local function recheck_later(session_id, block_id)
	rex.after(1, function()
		local r = rex.block.call(terminal, "process", { session_id = session_id, block_id = block_id })
		if r then
			update(session_id, block_id, r.foreground, r.ancestors, true)
		end
	end)
end

update = function(session_id, block_id, foreground, ancestors, rechecked)
	if owners[block_id] then
		return
	end
	if runs_claude(foreground, ancestors) then
		if not claude_panes[block_id] then
			claude_started(session_id, block_id)
		end
	elseif claude_panes[block_id] then
		claude_stopped(block_id)
	elseif not rechecked then
		recheck_later(session_id, block_id)
	end
end

for _, c in ipairs(check(rex.call("client.list")).clients) do
	if c.info and c.info.label == client_label then
		rex.stop(0)
	end
end
check(rex.call("client.set_label", { label = client_label }))

-- Crab panes left by an earlier copy are closed and opened again, so this
-- copy knows which tab each belongs to.
for _, s in ipairs(check(rex.call("session.list")).sessions) do
	-- Block methods only reach sessions this connection is attached to.
	check(rex.call("session.attach", { session_id = s.session_id }))
	local blocks = check(rex.call("session.list_blocks", { session_id = s.session_id })).blocks
	for _, b in ipairs(blocks) do
		if b.label == label then
			rex.call("block.close", { session_id = s.session_id, block_id = b.block_id })
		end
	end
	for _, b in ipairs(blocks) do
		if b.creator_name == terminal and b.placement == "placed" and b.label ~= label then
			local r = rex.block.call(terminal, "process", { session_id = s.session_id, block_id = b.block_id })
			if r then
				update(s.session_id, b.block_id, r.foreground, r.ancestors, true)
			end
		end
	end
end

rex.on("session_created", function(_, ev)
	local _, err = rex.call("session.attach", { session_id = ev.session_id })
	if err ~= nil then
		rex.log("warn", "attaching to a new session: " .. err)
	end
end)

rex.on("terminal.process_changed", function(ctx, ev)
	update(ctx.session_id, ctx.block_id, ev.foreground, ev.ancestors)
end)

rex.on("block_created", function(ctx)
	refit(ctx.session_id)
end)

rex.on("block_closed", function(ctx, ev)
	local id = ev.block_id
	if not owners[id] then
		refit(ctx.session_id)
	end
	if owners[id] then
		local tab = tabs[owners[id]]
		owners[id] = nil
		if tab then
			tab.crabs = false
		end
	elseif claude_panes[id] then
		claude_stopped(id)
	end
end)
