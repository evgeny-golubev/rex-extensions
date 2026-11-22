-- The task providers that the task tabs and the task actions share: their
-- commands in providers/, their tabs, and each tab's state file.
local M = {}

--- Provider name -> the name shown to the user.
M.names = { google = "Google Tasks", apple = "Apple Reminders" }

local files = { google = "google-tasks", apple = "apple-reminders" }

--- Provider name -> its tab's name and state file.
M.tabs = { google = "Tasks", apple = "Reminders" }
M.state_files = { google = "tasks_state.json", apple = "reminders_state.json" }

--- The command of a provider in the extension folder `base`, or nil for an
--- unknown name.
function M.command(base, name)
	return files[name] and (base .. "providers/" .. files[name])
end

--- A state file's contents in folder `base`, with each table field the tab
--- uses present. `file` is tasks_state.json unless given.
function M.read_state(base, file)
	local f = io.open(base .. (file or "tasks_state.json"), "rb")
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
function M.write_state(base, s, file)
	local path = base .. (file or "tasks_state.json")
	local f = io.open(path .. ".tmp", "wb")
	if f then
		f:write(rex.json.encode(s))
		f:close()
		os.rename(path .. ".tmp", path)
	end
end

--- Moves the settings of the single Tasks tab, which earlier versions had,
--- to the tab of the provider it used: its state file and its place in the
--- tab settings. Does nothing once done.
function M.migrate(base, settings)
	local s = M.read_state(base)
	local name = s.provider == "apple" and "apple" or "google"
	if s.provider == "apple" and not io.open(base .. M.state_files.apple, "rb") then
		os.rename(base .. "tasks_state.json", base .. M.state_files.apple)
	end
	local order, hidden = settings.tabs(base)
	local target = M.tabs[name]
	for i, tab in ipairs(order) do
		if (tab == "Tasks" or tab == "Google Tasks") and tab ~= target then
			order[i] = target
			hidden[target], hidden[tab] = hidden[tab], nil
			settings.set_tabs(base, order, hidden)
			return
		end
	end
end

return M
