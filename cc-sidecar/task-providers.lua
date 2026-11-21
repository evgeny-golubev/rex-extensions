-- The task providers that the Tasks tab and the task actions share: their
-- commands in providers/, and the state file that holds the chosen one.
local M = {}

--- Provider name -> the name shown to the user.
M.names = { google = "Google Tasks", apple = "Apple Reminders" }

local files = { google = "google-tasks", apple = "apple-reminders" }

--- The command of a provider in the extension folder `base`, or nil for an
--- unknown name.
function M.command(base, name)
	return files[name] and (base .. "providers/" .. files[name])
end

--- The state file's contents in folder `base`, with each table field the tab
--- uses present.
function M.read_state(base)
	local f = io.open(base .. "tasks_state.json", "rb")
	local ok, s = false, nil
	if f then
		ok, s = pcall(rex.json.decode, f:read("*a"))
		f:close()
	end
	s = ok and type(s) == "table" and s or {}
	for _, field in ipairs({ "review", "snoozed", "dues", "moves", "proposals" }) do
		s[field] = type(s[field]) == "table" and s[field] or {}
	end
	return s
end

--- Writes the state file through a temporary file, so a reader never sees
--- half of it.
function M.write_state(base, s)
	local path = base .. "tasks_state.json"
	local f = io.open(path .. ".tmp", "wb")
	if f then
		f:write(rex.json.encode(s))
		f:close()
		os.rename(path .. ".tmp", path)
	end
end

return M
