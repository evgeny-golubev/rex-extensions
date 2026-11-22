-- The Google Tasks tab: the day's work from Google Tasks, with steps. The
-- tab itself is the shared core in tasks-core.lua; see the README.
local sidecar = ...
return assert(loadfile(sidecar.dir .. "tasks-core.lua"))(sidecar, {
	name = "Google Tasks",
	provider = "google",
	state_file = "tasks_state.json",
	steps = true,
})
