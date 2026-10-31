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
	'mkdir -p ~/.config/rex/state; for i in 1 2 3 4 5 6 7 8 9 10; do "$@" && break; sleep 1; done 2>>~/.config/rex/state/changes-pane.log',
	"sh",
	rex_binary,
	"--autostart=false",
	"do",
	"--all",
	home .. "/.config/rex/extensions/changes-pane/watcher.lua",
}, { detach = true, stdout = false, stderr = false })
