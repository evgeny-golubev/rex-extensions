-- Starts watcher.lua, which opens a changes pane beside each Claude Code pane,
-- on every config load. The server runs this file at start and only accepts
-- connections once it is done, so the retries cover a server that isn't
-- listening yet.
local home = os.getenv("HOME")
local rex_binary = home
	.. "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"

rex.exec.start({
	"/bin/sh",
	"-c",
	'mkdir -p ~/.config/rex/state; for i in 1 2 3 4 5 6 7 8 9 10; do "$@" && break; sleep 1; done 2>>~/.config/rex/state/cc-pane.log',
	"sh",
	rex_binary,
	"--autostart=false",
	"do",
	"--all",
	home .. "/.config/rex/extensions/cc-pane/watcher.lua",
}, { detach = true, stdout = false, stderr = false })

-- Palette actions. The title names what the toggle will do, and Rex only reads
-- titles when it loads this file, so the toggle reloads the config.
local base = home .. "/.config/rex/extensions/cc-pane/"
local settings = dofile(base .. "settings.lua")

rex.action({
	name = "cc_pane_show",
	title = "Show Changes Pane",
	category = "Claude Code",
	run = function(ctx)
		if not ctx.session_id or not ctx.block_id then
			error("no focused pane to show the changes pane for", 0)
		end
		settings.request_show(base, ctx.session_id, ctx.block_id)
	end,
})

rex.action({
	name = "cc_pane_auto_show",
	title = (settings.auto_show(base) and "Disable" or "Enable") .. " Changes Pane Auto-Show",
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
