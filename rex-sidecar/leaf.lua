-- leaf (https://leaf.dipxsy.app) shows the sidecar's diffs and Rex View's
-- documents and pictures when it's installed. Where it may be: Homebrew, the
-- curl installer and cargo, the places diff-view and viewer also look.
local L = {}

L.brew_install = "brew install deepanshumishraa/tap/leaf"

--- leaf's path, or nil when it isn't installed.
function L.path(home)
	for _, path in ipairs({ "/opt/homebrew/bin/leaf", "/usr/local/bin/leaf", home .. "/.local/bin/leaf", home .. "/.cargo/bin/leaf" }) do
		local f = io.open(path, "rb")
		if f then
			f:close()
			return path
		end
	end
end

return L
