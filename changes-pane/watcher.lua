-- Opens a "Changes" pane beside every pane that runs Claude Code, and closes
-- it when Claude exits. The pane runs panel.lua, which shows the Claude
-- session's activity and context, and a repository's uncommitted changes.
-- init.lua starts it with every config load (`rex do --all watcher.lua`).

local terminal = "com.superlogical.terminal"
local dir = debug.getinfo(1, "S").source:match("^@?(.*/)")
local viewer = dir .. "panel.lua"
local home = os.getenv("HOME") or ""
local rex_binary = home
	.. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"

--- Marks this script's server connection, so a second copy started by
--- `rex config reload` sees the first one and quits.
local client_label = "changes-pane"

--- Every changes pane's label starts with this; claude-resume skips them.
local label_prefix = "Changes: "

--- The share of the split the Claude pane keeps.
local claude_ratio = 0.8

--- Claude pane block ID -> { session_id, changes = block ID or nil }. An
--- entry stays while Claude runs even without a changes pane (the user
--- closed it), so the pane isn't opened again until Claude exits.
local claude_panes = {}
--- Changes pane block ID -> its Claude pane's block ID.
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

local function is_changes_label(label)
	return label ~= nil and label:sub(1, #label_prefix) == label_prefix
end

local function repo_root(cwd)
	if not cwd then
		return nil
	end
	local r = rex.exec({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }, { timeout = 5 })
	if r and r.ok then
		return (r.stdout:gsub("%s+$", ""))
	end
end

--- The app re-balances a new split in the tab it shows, so the ratio is set
--- again once it has.
local function keep_ratio(session_id, before, after)
	rex.after(0.5, function()
		local _, err = rex.call("session.resize_pane", {
			session_id = session_id,
			direction = "horizontal",
			before_block_id = before,
			after_block_id = after,
			ratio = claude_ratio,
		})
		if err ~= nil then
			rex.log("warn", "sizing a changes pane: " .. err)
		end
	end)
end

--- Opens a changes pane to the right of the Claude pane, in its repository's
--- root or its own directory, and returns its block ID.
local function open(session_id, block_id, cwd)
	local root = repo_root(cwd) or cwd or home
	local result, err = rex.call("session.new_split", {
		session_id = session_id,
		anchor_id = block_id,
		direction = "horizontal",
		side = "after",
		ratio = claude_ratio,
		focus = false,
		layout = {
			block = {
				flavor = terminal .. ".shell",
				label = label_prefix .. (root:match("[^/]+$") or root),
				options = {
					command = { rex_binary, "--autostart=false", "do", viewer, "claude=" .. block_id, "cwd=" .. root },
					shell = "none",
					cwd = root,
				},
			},
		},
	})
	if err ~= nil then
		rex.log("warn", "opening a changes pane: " .. err)
		return nil
	end
	local changes = result.block_ids[1]
	owners[changes] = block_id
	keep_ratio(session_id, block_id, changes)
	return changes
end

local function close(block_id)
	local pane = claude_panes[block_id]
	claude_panes[block_id] = nil
	if pane and pane.changes then
		owners[pane.changes] = nil
		local _, err = rex.call("block.close", { session_id = pane.session_id, block_id = pane.changes })
		if err ~= nil then
			rex.log("warn", "closing a changes pane: " .. err)
		end
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
			local cwd = foreground and foreground.cwd
			claude_panes[block_id] = { session_id = session_id, changes = open(session_id, block_id, cwd) }
		end
	elseif claude_panes[block_id] then
		close(block_id)
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

-- Changes panes left by an earlier copy are closed and opened again, so this
-- copy knows which Claude pane each belongs to.
for _, s in ipairs(check(rex.call("session.list")).sessions) do
	-- Block methods only reach sessions this connection is attached to.
	check(rex.call("session.attach", { session_id = s.session_id }))
	local blocks = check(rex.call("session.list_blocks", { session_id = s.session_id })).blocks
	for _, b in ipairs(blocks) do
		if is_changes_label(b.label) then
			rex.call("block.close", { session_id = s.session_id, block_id = b.block_id })
		end
	end
	for _, b in ipairs(blocks) do
		if b.creator_name == terminal and b.placement == "placed" and not is_changes_label(b.label) then
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

rex.on("block_closed", function(_, ev)
	local id = ev.block_id
	if owners[id] then
		claude_panes[owners[id]].changes = nil
		owners[id] = nil
	elseif claude_panes[id] then
		close(id)
	end
end)
