-- Rex actions that let an agent such as Claude Code use the task list that the
-- Tasks tab shows, through the provider chosen in the tab:
--   tasks_list          the open tasks of every list.
--   tasks_add           adds a task and returns its ID.
--   tasks_report_done   reports a task done. The report waits in the tab's
--                       Attention section until the user confirms or rejects it.
-- Run them as: rex do tasks_add title="A. Write the report (1h)" due=today
--- The extension folder, which the loader passes.
local dir = ...
local providers = dofile(dir .. "task-providers.lua")
--- The folder of tasks_state.json: a throwaway one in the tests.
local state_dir = REX_SIDECAR_TEST_BASE or dir

--- Runs the chosen provider with `args` and returns its decoded JSON output.
local function provider(args)
	local command = providers.command(dir, providers.read_state(state_dir).provider)
	if not command then
		error("No task source chosen: open the Tasks tab in the sidecar pane and choose one.", 0)
	end
	local r = rex.exec({ command, unpack(args) }, { timeout = 60 })
	if not r then
		error("The task provider did not answer.", 0)
	elseif r.code == 3 then
		error("Sign-in needed: press L in the Tasks tab.", 0)
	elseif r.code == 4 then
		error("The task source is not set up: " .. ((r.stderr or ""):match("[^\n]+") or "see the Tasks tab."), 0)
	elseif not r.ok then
		error("The task provider failed: " .. (((r.stdout or "") .. (r.stderr or "")):match("[^\n]+") or "no output"), 0)
	end
	local ok, value = pcall(rex.json.decode, r.stdout)
	return ok and value or r.stdout
end

--- Applies `change`, when given, to the state file and records the time, so
--- the tab fetches the lists at its next state check.
local function record(change)
	local s = providers.read_state(state_dir)
	if change then
		change(s)
	end
	s.changed_at = os.time()
	providers.write_state(state_dir, s)
end

--- "today", "tomorrow" or YYYY-MM-DD as YYYY-MM-DD.
local function date_of(text)
	if text == "today" then
		return os.date("%Y-%m-%d")
	elseif text == "tomorrow" then
		return os.date("%Y-%m-%d", os.time() + 86400)
	elseif text:match("^%d%d%d%d%-%d%d%-%d%d$") then
		return text
	end
	error("A due date is today, tomorrow or YYYY-MM-DD, not " .. text, 0)
end

rex.action({
	name = "tasks_list",
	title = "Tasks: List Open Tasks",
	description = "Lists the open tasks of the task list the sidecar Tasks tab shows.",
	category = "Tasks",
	run = function()
		local out = {}
		for _, list in ipairs(provider({ "tasks" })) do
			local tasks = {}
			for _, t in ipairs(list.tasks or {}) do
				tasks[#tasks + 1] = { id = t.id, title = t.title, due = t.due, parent = t.parent }
			end
			out[#out + 1] = { id = list.id, title = list.title, tasks = tasks }
		end
		return out
	end,
})

rex.action({
	name = "tasks_add",
	title = "Tasks: Add Task",
	description = "Adds a task to the task list the sidecar Tasks tab shows. The title starts with a rating, \"A. \", \"B. \" or \"C. \", and may end with an estimate, \"(30m)\". A due date is required.",
	category = "Tasks",
	args = { title = "string", due = "string", notes = "string?", list = "string?", parent = "string?" },
	run = function(_, args)
		if not args.due or args.due == "" then
			error("A due date is required: today, tomorrow or YYYY-MM-DD.", 0)
		end
		if not args.parent and not args.title:match("^[ABC]%. ") then
			error("The title must start with a rating: \"A. \", \"B. \" or \"C. \".", 0)
		end
		local due = date_of(args.due)
		local list = args.list or (provider({ "tasks" })[1] or error("The task source has no lists.", 0)).id
		local argv = { "add", list, "--due", due }
		if args.notes then
			argv[#argv + 1], argv[#argv + 2] = "--notes", args.notes
		end
		if args.parent then
			argv[#argv + 1], argv[#argv + 2] = "--parent", args.parent
		end
		argv[#argv + 1] = args.title
		local added = provider(argv)
		record()
		return { id = added.id, list = list, title = args.title }
	end,
})

rex.action({
	name = "tasks_report_done",
	title = "Tasks: Report Task Done",
	description = "Reports a task done. The report waits in the Attention section of the sidecar Tasks tab until the user confirms it with y or rejects it with n.",
	category = "Tasks",
	args = { id = "string", note = "string?" },
	run = function(_, args)
		local task
		for _, list in ipairs(provider({ "tasks" })) do
			for _, t in ipairs(list.tasks or {}) do
				if t.id == args.id and t.status ~= "completed" then
					task = t
				end
			end
		end
		if not task then
			error("No open task with ID " .. args.id, 0)
		end
		record(function(s)
			s.proposals[args.id] = { note = args.note or "" }
		end)
		return { reported = args.id, title = task.title }
	end,
})
