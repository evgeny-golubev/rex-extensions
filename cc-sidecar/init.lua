-- Starts watcher.lua, which opens a sidecar pane beside each Claude Code pane,
-- on every config load. The server runs this file at start and only accepts
-- connections once it is done, so the retries cover a server that isn't
-- listening yet.
local home = os.getenv("HOME")
local rex_binary = home
	.. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"

rex.exec.start({
	"/bin/sh",
	"-c",
	'mkdir -p ~/.config/rex/state; for i in 1 2 3 4 5 6 7 8 9 10; do "$@" && break; sleep 1; done 2>>~/.config/rex/state/cc-sidecar.log',
	"sh",
	rex_binary,
	"--autostart=false",
	"do",
	"--all",
	home .. "/.config/rex/extensions/cc-sidecar/watcher.lua",
}, { detach = true, stdout = false, stderr = false })

-- Palette actions. The title names what the toggle will do, and Rex only reads
-- titles when it loads this file, so the toggle reloads the config.
local base = home .. "/.config/rex/extensions/cc-sidecar/"
local settings = dofile(base .. "settings.lua")

rex.action({
	name = "cc_sidecar_show",
	title = "Show Sidecar Pane",
	category = "Claude Code",
	run = function(ctx)
		if not ctx.session_id or not ctx.block_id then
			error("no focused pane to show the sidecar pane for", 0)
		end
		settings.request_show(base, ctx.session_id, ctx.block_id)
	end,
})

rex.action({
	name = "cc_sidecar_auto_show",
	title = (settings.auto_show(base) and "Disable" or "Enable") .. " Sidecar Pane Auto-Show",
	category = "Claude Code",
	run = function()
		local on = not settings.auto_show(base)
		settings.set_auto_show(base, on)
		rex.exec.start(
			{ rex_binary, "--autostart=false", "config", "reload" },
			{ detach = true, stdout = false, stderr = false }
		)
		return { auto_show = on }
	end,
})

-- Rex View: a picker for the files, images and links in Claude's last replies,
-- in a float over the tab. Its floats are labelled like rex-view's, so each
-- replaces the one before.
local claude = dofile(base .. "claude.lua")
local terminal = "com.superlogical.terminal"
local view_prefix = "View: "

local function window_of(view, block_id)
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

local function session_view(ctx)
	local r, err = rex.session.view({ session_id = ctx.session_id })
	if not r then
		error("Rex View: " .. tostring(err), 0)
	end
	return r.view or r
end

--- The focused pane if it runs Claude, or else the first one in the tab that does.
local function tab_claude(ctx, window)
	local blocks = { ctx.block_id }
	for _, l in ipairs(window.layers or {}) do
		if l.kind == "tiled" then
			for _, b in ipairs(l.blocks or {}) do
				blocks[#blocks + 1] = b.block_id
			end
		end
	end
	for _, id in ipairs(blocks) do
		local process = id and rex.block.call(terminal, "process", { session_id = ctx.session_id, block_id = id })
		if claude.pid(process) then
			return id
		end
	end
end

local function open_float(ctx, window, label, command)
	for _, l in ipairs(window.layers or {}) do
		if l.kind ~= "tiled" then
			for _, b in ipairs(l.blocks or {}) do
				if (b.label or ""):sub(1, #view_prefix) == view_prefix then
					rex.session.close_layer({ session_id = ctx.session_id, layer_id = l.layer_id })
					break
				end
			end
		end
	end
	local r, err = rex.session.new_layer({
		session_id = ctx.session_id,
		window_id = window.window_id,
		bounds = { 0.15, 0.1, 0.7, 0.7 },
		focus = true,
		layout = { block = { flavor = "com.superlogical.terminal.shell", label = view_prefix .. label, options = { command = command } } },
	})
	if not r then
		error("Rex View: " .. tostring(err), 0)
	end
end

--- The tab the action runs in: the focused pane's, or the active one.
local function current_window(ctx)
	local view = session_view(ctx)
	local window = ctx.block_id and window_of(view, ctx.block_id)
	if not window then
		for _, w in ipairs(view.windows or {}) do
			if w.window_id == view.active_window_id then
				window = w
			end
		end
	end
	if not window then
		error("Rex View: no tab to open in", 0)
	end
	return window
end

rex.action({
	name = "cc_sidecar_view",
	title = "Rex View: Open from Claude's Replies",
	description = "Lists the files, images and links in Claude's last replies, to view, edit or open.",
	category = "Claude Code",
	keywords = "rex view open file image link url pr jira editor picker",
	run = function(ctx)
		local window = current_window(ctx)
		local block = tab_claude(ctx, window)
		if not block then
			error("Rex View: no Claude Code in this tab", 0)
		end
		open_float(ctx, window, "Claude's replies", { base .. "view-picker", rex_binary, ctx.session_id, block })
	end,
})

rex.action({
	name = "cc_sidecar_view_editor",
	title = "Rex View: Set Editor",
	description = "Sets the command Rex View edits files with.",
	category = "Claude Code",
	run = function(ctx)
		open_float(ctx, current_window(ctx), "editor", { base .. "view-settings", "editor" })
	end,
})

rex.action({
	name = "cc_sidecar_view_patterns",
	title = "Rex View: Edit Link Patterns",
	description = "Adds, edits and deletes the patterns that turn text such as Jira keys or PR numbers into links.",
	category = "Claude Code",
	run = function(ctx)
		local window = current_window(ctx)
		local block = tab_claude(ctx, window)
		local process = block and rex.block.call(terminal, "process", { session_id = ctx.session_id, block_id = block })
		local pid = claude.pid(process)
		local cwd = pid and select(2, claude.transcript(pid)) or "/"
		open_float(ctx, window, "link patterns", { base .. "view-settings", "patterns", cwd })
	end,
})

rex.bind("cmd+ctrl+alt+shift+o", "cc_sidecar_view")
