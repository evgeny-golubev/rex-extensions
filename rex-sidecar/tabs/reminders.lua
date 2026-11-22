-- The Reminders tab: the day's work from Apple Reminders. The tab itself is
-- the shared core in tasks-core.lua; see the README.
local sidecar = ...
return assert(loadfile(sidecar.dir .. "tasks-core.lua"))(sidecar, {
	name = "Reminders",
	provider = "apple",
	state_file = "reminders_state.json",
})
