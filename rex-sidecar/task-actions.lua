-- Rex actions that let an agent such as Claude Code use the task lists that
-- the sidecar's Google Tasks and Reminders tabs show. Only a shown tab's
-- provider is asked, so a source you don't use is never run.
--   tasks_list          the open tasks of every list, each with its provider.
--   tasks_add           adds a task and returns its ID.
--   tasks_report_done   reports a task done. The report waits in the tab's
--                       Attention section until the user confirms or rejects it.
-- Run them as: rex do tasks_add title="A. Write the report (1h)" due=today
--- The extension folder, which the loader passes.
local dir = ...
local providers = dofile(dir .. "task-providers.lua")
local settings = dofile(dir .. "settings.lua")
--- The folder of settings.json and the state files: a throwaway one in the tests.
local state_dir = REX_SIDECAR_TEST_BASE or dir

--- The providers whose tab is shown, Google first.
local function shown()
	local order, hidden = settings.tabs(state_dir)
	local listed = {}
	for _, name in ipairs(order) do
		listed[name] = not hidden[name]
	end
	local out = {}
	for _, name in ipairs({ "google", "apple" }) do
		if listed[providers.tabs[name]] then
			out[#out + 1] = name
		end
	end
	return out
end

--- Runs provider `name` with `args` and returns its decoded JSON output.
local function run(name, args)
	local tab = providers.tabs[name]
	local r = rex.exec({ providers.command(dir, name), unpack(args) }, { timeout = 60 })
	if not r then
		error(providers.names[name] .. " did not answer.", 0)
	elseif r.code == 3 then
		error("Sign-in needed: press L in the " .. tab .. " tab.", 0)
	elseif r.code == 4 then
		error(providers.names[name] .. " is not set up: " .. ((r.stderr or ""):match("[^\n]+") or "see the " .. tab .. " tab."), 0)
	elseif not r.ok then
		error(providers.names[name] .. " failed: " .. (((r.stdout or "") .. (r.stderr or "")):match("[^\n]+") or "no output"), 0)
	end
	local ok, value = pcall(rex.json.decode, r.stdout)
	return ok and value or r.stdout
end

--- The lists of provider `name`, without the Reminders lists hidden in its tab.
local function lists_of(name)
	local hidden = providers.read_state(state_dir, providers.state_files[name]).hidden_lists
	local out = {}
	for _, list in ipairs(run(name, { "tasks" })) do
		if not (type(hidden) == "table" and hidden[list.id]) then
			out[#out + 1] = list
		end
	end
	return out
end

--- Applies `change`, when given, to provider `name`'s state file and records
--- the time, so its tab fetches the lists at its next state check.
local function record(name, change)
	local file = providers.state_files[name]
	local s = providers.read_state(state_dir, file)
	if change then
		change(s)
	end
	s.changed_at = os.time()
	providers.write_state(state_dir, s, file)
end

--- The providers to use: `wanted` alone when given, else the shown ones.
local function sources(wanted)
	if wanted and wanted ~= "" then
		if not providers.names[wanted] then
			error("A provider is google or apple, not " .. wanted, 0)
		end
		return { wanted }
	end
	local list = shown()
	if #list == 0 then
		error("No task tab is shown: in the sidecar, press , and show Google Tasks or Reminders.", 0)
	end
	return list
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

--- The lists of each provider in `names` that answers, each with its
--- provider. A failing provider is skipped while another answers, so an
--- ended Google sign-in doesn't hide the Reminders tasks; with none
--- answering, the first error is raised.
local function all_lists(names)
	local out, first_error = {}, nil
	for _, name in ipairs(names) do
		local ok, lists = pcall(lists_of, name)
		if ok then
			for _, list in ipairs(lists) do
				out[#out + 1] = { name = name, list = list }
			end
		else
			first_error = first_error or lists
		end
	end
	if #out == 0 and first_error then
		error(first_error, 0)
	end
	return out
end

rex.action({
	name = "tasks_list",
	title = "Tasks: List Open Tasks",
	description = "Lists the open tasks of the lists the sidecar's Google Tasks and Reminders tabs show, each list with its provider.",
	category = "Tasks",
	args = { provider = "string?" },
	run = function(_, args)
		local out = {}
		for _, found in ipairs(all_lists(sources(args and args.provider))) do
			local list, tasks = found.list, {}
			for _, t in ipairs(list.tasks or {}) do
				if t.status ~= "completed" then
					tasks[#tasks + 1] = { id = t.id, title = t.title, due = t.due, parent = t.parent,
						rating = t.priority or (t.title or ""):match("^([ABC])%. ") }
				end
			end
			out[#out + 1] = { provider = found.name, id = list.id, title = list.title, tasks = tasks }
		end
		return out
	end,
})

rex.action({
	name = "tasks_add",
	title = "Tasks: Add Task",
	description = "Adds a task to a list the sidecar's task tabs show. The title starts with a rating, \"A. \", \"B. \" or \"C. \", and may end with an estimate, \"(30m)\". A due date is required. provider is google or apple; without it, the provider of list, or else the only task tab shown, or else Google Tasks.",
	category = "Tasks",
	args = { title = "string", due = "string", notes = "string?", list = "string?", parent = "string?", provider = "string?" },
	run = function(_, args)
		if not args.due or args.due == "" then
			error("A due date is required: today, tomorrow or YYYY-MM-DD.", 0)
		end
		if not args.parent and not args.title:match("^[ABC]%. ") then
			error("The title must start with a rating: \"A. \", \"B. \" or \"C. \".", 0)
		end
		local due = date_of(args.due)
		local candidates = sources(args.provider)
		local name, list = nil, args.list
		if list and #candidates > 1 then
			for _, found in ipairs(all_lists(candidates)) do
				name = name or (found.list.id == list and found.name) or nil
			end
		end
		name = name or (#candidates == 1 and candidates[1]) or "google"
		if name == "apple" and args.parent then
			error("Reminders has no steps: add the step as a task of its own.", 0)
		end
		if not list then
			local default = name == "apple" and providers.read_state(state_dir, providers.state_files.apple).default_list
			list = default or (lists_of(name)[1] or error(providers.names[name] .. " has no lists.", 0)).id
		end
		local argv, title = { "add", list, "--due", due }, args.title
		if name == "apple" then
			-- Reminders keeps the rating in its Priority field.
			local rating, rest = title:match("^([ABC])%.%s+(.*)$")
			if rating then
				title = rest
				argv[#argv + 1], argv[#argv + 2] = "--priority", rating
			end
		end
		if args.notes then
			argv[#argv + 1], argv[#argv + 2] = "--notes", args.notes
		end
		if args.parent then
			argv[#argv + 1], argv[#argv + 2] = "--parent", args.parent
		end
		argv[#argv + 1] = title
		local added = run(name, argv)
		record(name)
		return { id = added.id, list = list, provider = name, title = args.title }
	end,
})

rex.action({
	name = "tasks_report_done",
	title = "Tasks: Report Task Done",
	description = "Reports a task done. The report waits in the Attention section of its sidecar task tab until the user confirms it with y or rejects it with n.",
	category = "Tasks",
	args = { id = "string", note = "string?", provider = "string?" },
	run = function(_, args)
		local task, name
		for _, found in ipairs(all_lists(sources(args.provider))) do
			for _, t in ipairs(found.list.tasks or {}) do
				if t.id == args.id and t.status ~= "completed" then
					task, name = t, found.name
				end
			end
		end
		if not task then
			error("No open task with ID " .. args.id, 0)
		end
		record(name, function(s)
			s.proposals[args.id] = { note = args.note or "" }
		end)
		return { reported = args.id, provider = name, title = task.title }
	end,
})
