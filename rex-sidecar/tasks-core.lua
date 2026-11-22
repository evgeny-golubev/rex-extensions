-- The task tabs' shared core: the day's work from a task provider, ordered by
-- A, B and C ratings, with a daily review. tabs/google-tasks.lua and
-- tabs/reminders.lua load it with the sidecar module and a config:
--   name        the tab's name.
--   provider    the provider's name in task-providers.lua.
--   state_file  the state file's name, beside settings.json.
--   steps       true when the provider has subtasks.
--   priority    true when the rating is the task's priority field, not a
--               title prefix.
--   lists       true for the list keys: l chooses the lists shown and the
--               default list for new tasks, m moves a task to another list.
-- Each tab is hidden until shown in the tab settings; see the README.
--
-- Provider contract. A provider is a command in providers/, named in
-- task-providers.lua.
--   tasks [--completed-since DATE]
--       Prints JSON: [{ id, title, tasks = [{ id, title, due, notes, parent,
--       status, completed, recurring }] }]. due is YYYY-MM-DD or "". parent is
--       a task ID or null. status is "needsAction" or "completed". completed is
--       the local date of completion, YYYY-MM-DD. recurring is optional: true
--       when the provider knows the task repeats. Open tasks come in the
--       user's order.
--       With --completed-since, tasks completed on or after DATE are included.
--   add LIST [--due DATE] [--notes TEXT] [--parent TASK] [--previous TASK] TITLE
--       Prints JSON: { id }. The task goes after --previous when given. A
--       provider without subtasks refuses --parent with a message.
--   update LIST TASK [--title TEXT] [--due DATE] [--notes TEXT] [--status STATUS]
--       An empty DATE clears the due date.
--   login
--       Signs in interactively.
--   Exit code 3, or the JSON { error = "auth_required" }, means sign-in is needed;
--   its detail "sign-in expired" means an earlier sign-in ended.
--   Exit code 4 means the provider is not set up; standard error says how to set it up.
--
-- Conventions in the provider's tasks:
--   Rating       title prefix "A. ", "B. " or "C. ".
--   Estimate     title suffix "(30m)", "(2h)" or "(1h30)".
--   Planned day  the due date: the day the task is to be finished by.
--   Steps        subtasks, one level deep.
-- A task is recurring when its title, without rating and estimate, is among
-- the completed tasks twice, or once while a task with that title is open.
-- The review date and streak, snoozes, due-date changes and reports from the
-- task actions are kept in the tab's state file beside settings.json, which
-- every sidecar pane shares.
local sidecar, config = ...
local c = sidecar.colours
local width, clip = sidecar.width, sidecar.clip
local providers = dofile(sidecar.dir .. "task-providers.lua")
--- Whether the provider has subtasks, which the tab shows as steps.
local STEPS = config.steps == true
--- Whether the rating is kept in the provider's priority field.
local PRIORITY = config.priority == true
--- Whether the tab chooses lists and moves tasks between them.
local LISTS = config.lists == true
pcall(providers.migrate, sidecar.settings_dir, sidecar.settings)

--- Minutes of planned work that fit in one day.
local CAPACITY = 360
--- A one-off task without an estimate counts as CAPACITY / TODAY_LIMIT minutes
--- in the day's load and CAPACITY / A_LIMIT minutes in the A load. Without any
--- estimates, the warnings therefore start above 5 tasks today and 3 A tasks.
local TODAY_LIMIT, A_LIMIT = 5, 3
--- Minutes counted for a recurring task without an estimate.
local RECURRING_MINUTES = 15
--- A task estimated above this many minutes is to be split into steps, and
--- a step is to be no longer.
local SPLIT_MINUTES = 120
--- A task without estimate or steps this many days past due is to be split.
local SPLIT_DAYS = 7
--- An A task is slipping this many days past due, or after this many date changes.
local SLIP_DAYS, SLIP_MOVES = 3, 3
--- Days of completed tasks fetched, for Done today and recurring tasks.
local HISTORY_DAYS = 60
--- The note a dropped task is completed with.
local DROP_NOTE = "Dropped in review"
--- Seconds between fetches of the lists when nothing changed outside the tab.
local FETCH_SECONDS = 60

local lib = {}

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- The time at noon of a YYYY-MM-DD date.
local function noon(date)
	local y, m, d = date:match("^(%d+)%-(%d+)%-(%d+)$")
	return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
end

function lib.add_days(date, n)
	return os.date("%Y-%m-%d", noon(date) + n * 86400)
end

--- Days from one date to another; negative when `to` is earlier.
function lib.days_between(from, to)
	return math.floor((noon(to) - noon(from)) / 86400 + 0.5)
end

local weekdays = { "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" }
local months = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- A date as "Mon 23", or with `month` as "Mon 23 Nov". Written out here, as
--- this runtime's os.date gives day names in lower case.
function lib.day_text(date, month)
	local t = os.date("*t", noon(date))
	local day = weekdays[t.wday]
	return day:sub(1, 1):upper() .. day:sub(2, 3) .. " " .. t.day .. (month and (" " .. months[t.month]) or "")
end

--- A typed date as YYYY-MM-DD: "today", "tomorrow", a weekday or its first
--- three letters (the next such day after today), "+N" days, or YYYY-MM-DD.
--- Empty text gives "", which clears a date; text not understood gives nil.
function lib.parse_date(text, today)
	text = trim(text:lower())
	if text == "" then
		return ""
	elseif text == "today" then
		return today
	elseif text == "tomorrow" then
		return lib.add_days(today, 1)
	end
	local n = text:match("^%+(%d+)d?$")
	if n then
		return lib.add_days(today, tonumber(n))
	end
	local y, m, d = text:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
	if y then
		local date = os.date("%Y-%m-%d", os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }))
		if tonumber(date:sub(6, 7)) == tonumber(m) and tonumber(date:sub(9, 10)) == tonumber(d) then
			return date
		end
		return nil
	end
	if #text >= 3 then
		for i, name in ipairs(weekdays) do
			if name:sub(1, #text) == text then
				local now = os.date("*t", noon(today)).wday
				return lib.add_days(today, (i - now - 1) % 7 + 1)
			end
		end
	end
	return nil
end

--- Minutes from typed text: "15m", "1h", "1h30", "1.5h" or a bare number of
--- minutes. Nil when not understood or not above zero.
function lib.parse_estimate(text)
	text = text:lower():gsub("%s", "")
	local minutes
	local h, m = text:match("^(%d+)h(%d+)m?$")
	if h then
		minutes = tonumber(h) * 60 + tonumber(m)
	elseif text:match("^%d+h$") then
		minutes = tonumber(text:sub(1, -2)) * 60
	elseif text:match("^%d*%.%d+h$") then
		minutes = math.floor(tonumber(text:sub(1, -2)) * 60 + 0.5)
	elseif text:match("^%d+m?$") then
		minutes = tonumber((text:gsub("m$", "")))
	end
	return minutes and minutes > 0 and minutes or nil
end

--- Minutes as written in a title: "45m", "2h" or "1h30".
function lib.format_minutes(n)
	n = math.floor(n + 0.5)
	if n < 60 then
		return n .. "m"
	end
	local h, m = math.floor(n / 60), n % 60
	return m == 0 and (h .. "h") or string.format("%dh%02d", h, m)
end

--- A title's rating ("A", "B", "C" or nil), its name, and its estimate in
--- minutes or nil. An estimate suffix needs a unit, so "Taxes (2025)" keeps
--- its year.
function lib.parse_title(title)
	-- Directional marks, which phone numbers often carry, take no column.
	title = title:gsub("\226\128[\142\143\170-\174]", ""):gsub("\226\129[\166-\169]", "")
	local rating, rest = title:match("^([ABC])%.%s+(.*)$")
	rest = rest or title
	local name, suffix = rest:match("^(.-)%s*%(([%d%.]+[hm][%dm]*)%)%s*$")
	local minutes = suffix and lib.parse_estimate(suffix)
	if not minutes then
		name = rest
	end
	return { rating = rating, name = trim(name), estimate = minutes }
end

function lib.compose_title(rating, name, estimate)
	return (rating and (rating .. ". ") or "") .. name .. (estimate and (" (" .. lib.format_minutes(estimate) .. ")") or "")
end

--- A title without rating and estimate, in lower case, to compare titles.
function lib.normal_title(title)
	return (lib.parse_title(title).name:lower():gsub("%s+", " "))
end

--- A typed task, "A. Title (20m) fri": its title, and its due date when the
--- last word is a date. A title of one word keeps that word.
function lib.parse_entry(text, today)
	text = trim(text)
	local head, word = text:match("^(.-)%s+(%S+)$")
	local due
	if head and trim(head) ~= "" then
		local date = lib.parse_date(word, today)
		if date and date ~= "" then
			due, text = date, trim(head)
		end
	end
	local p = lib.parse_title(text)
	return lib.compose_title(p.rating, p.name, p.estimate), due
end

function lib.dropped(task)
	return (task.notes or ""):find(DROP_NOTE, 1, true) ~= nil
end

--- The set of normal titles of recurring tasks: completed twice, or completed
--- once with an open task of the same title. Dropped tasks are not counted.
local function recurring_titles(open, completed)
	local count, set = {}, {}
	for _, t in ipairs(completed) do
		if not lib.dropped(t) then
			local key = lib.normal_title(t.title or "")
			count[key] = (count[key] or 0) + 1
		end
	end
	for key, n in pairs(count) do
		if n >= 2 then
			set[key] = true
		end
	end
	for _, r in ipairs(open) do
		local key = lib.normal_title(r.task.title or "")
		set[key] = set[key] or count[key] ~= nil
	end
	return set
end

local rating_rank = { A = 1, B = 2, C = 3 }

--- A task's rating: its priority field when the provider has one, else the
--- prefix of its parsed title `p`.
function lib.rating_of(t, p)
	return rating_rank[t.priority] and t.priority or p.rating
end

--- A before B before C before unrated, then the provider's order.
function lib.before(a, b)
	local ra, rb = rating_rank[a.rating] or 4, rating_rank[b.rating] or 4
	if ra ~= rb then
		return ra < rb
	end
	return a.order < b.order
end

--- The tasks of all lists, parsed. `open` holds the open top-level tasks in
--- the provider's order, `steps` maps a task ID to its open subtasks in order, `done`
--- holds the tasks completed today and not dropped, and `by` maps an ID to its
--- item. `moves` maps a task ID to the number of its due-date changes.
function lib.model(lists, today, moves)
	local m = { open = {}, steps = {}, done = {}, by = {}, today = today }
	local raw_open, raw_done, completed_ids = {}, {}, {}
	for _, list in ipairs(lists or {}) do
		for _, t in ipairs(list.tasks or {}) do
			if t.status == "completed" then
				raw_done[#raw_done + 1] = t
				completed_ids[t.id] = true
			else
				raw_open[#raw_open + 1] = { task = t, list = list }
			end
		end
	end
	local recurring = recurring_titles(raw_open, raw_done)
	local items = {}
	for i, r in ipairs(raw_open) do
		local t = r.task
		local p = lib.parse_title(t.title or "")
		local due = (t.due or "") ~= "" and t.due or nil
		local it = {
			id = t.id, task = t, list = r.list, order = i, rating = lib.rating_of(t, p), name = p.name, estimate = p.estimate, due = due,
			parent = type(t.parent) == "string" and t.parent or nil, pending = t.pending,
			recurring = t.recurring == true or recurring[lib.normal_title(t.title or "")] or false,
			late = due and due < today and lib.days_between(due, today) or 0,
			moves = moves and moves[t.id] or 0,
		}
		items[#items + 1] = it
		m.by[t.id] = it
	end
	for _, it in ipairs(items) do
		local parent = it.parent and m.by[it.parent]
		if parent and not parent.parent then
			m.steps[parent.id] = m.steps[parent.id] or {}
			table.insert(m.steps[parent.id], it)
			it.step_of = parent
		elseif not (it.parent and completed_ids[it.parent]) then
			m.open[#m.open + 1] = it
		end
	end
	for _, t in ipairs(raw_done) do
		if t.completed == today and not lib.dropped(t) and type(t.parent) ~= "string" then
			local p = lib.parse_title(t.title or "")
			local it = { id = t.id, name = p.name, rating = lib.rating_of(t, p), estimate = p.estimate, done = true,
				recurring = recurring[lib.normal_title(t.title or "")] or false, late = 0, moves = 0 }
			m.done[#m.done + 1] = it
			m.by[t.id] = m.by[t.id] or it
		end
	end
	return m
end

--- The items for which `keep` is true, or all of them, A first.
local function sorted(items, keep)
	local out = {}
	for _, it in ipairs(items) do
		if not keep or keep(it) then
			out[#out + 1] = it
		end
	end
	table.sort(out, lib.before)
	return out
end

--- Open top-level tasks due today or earlier, A first.
function lib.today_items(m)
	return sorted(m.open, function(it)
		return it.due and it.due <= m.today
	end)
end

--- Open one-off A tasks.
function lib.a_items(m)
	return sorted(m.open, function(it)
		return it.rating == "A" and not it.recurring
	end)
end

--- One-off tasks past due, A first: the daily review's first stage.
function lib.late_items(m)
	return sorted(m.open, function(it)
		return it.late > 0 and not it.recurring
	end)
end

--- The one next action: the first of today's tasks, or else of the A tasks,
--- and its first open step when it has steps. Returns the item and, for a
--- step, the task it belongs to.
function lib.next_item(m)
	local first = lib.today_items(m)[1]
	if not first then
		for _, it in ipairs(sorted(m.open)) do
			if it.rating == "A" then
				first = it
				break
			end
		end
	end
	local step = first and m.steps[first.id] and m.steps[first.id][1]
	if step then
		return step, first
	end
	return first
end

--- Minutes of work left in a task: its open steps' estimates when any step
--- has one, else its own estimate, else nil.
function lib.remaining(m, it)
	local total, known = 0, false
	for _, s in ipairs(m.steps[it.id] or {}) do
		if s.estimate then
			total, known = total + s.estimate, true
		end
	end
	if known then
		return total
	end
	return it.estimate
end

--- Planned minutes in `items`, a task without an estimate counted as
--- RECURRING_MINUTES when recurring and CAPACITY / limit otherwise.
function lib.load(m, items, limit)
	local total = 0
	for _, it in ipairs(items) do
		total = total + (lib.remaining(m, it) or (it.recurring and RECURRING_MINUTES) or CAPACITY / limit)
	end
	return total
end

--- Estimated minutes left in `items`, and how many have no estimate.
function lib.time_left(m, items)
	local total, unknown = 0, 0
	for _, it in ipairs(items) do
		local n = lib.remaining(m, it)
		if n then
			total = total + n
		else
			unknown = unknown + 1
		end
	end
	return total, unknown
end

--- True when a one-off task without steps is too large for one day: estimated
--- above SPLIT_MINUTES, or without estimate and SPLIT_DAYS past due.
function lib.too_large(m, it)
	if not STEPS or it.recurring or it.step_of or (m.steps[it.id] and #m.steps[it.id] > 0) then
		return false
	end
	if it.estimate then
		return it.estimate > SPLIT_MINUTES
	end
	return it.late >= SPLIT_DAYS
end

--- The actions that suit a task, most useful first, each { key, label }: at
--- most two that fit its state, then done.
function lib.actions(m, it)
	if it.done then
		return { { "x", "not done" } }
	end
	local out = {}
	if lib.too_large(m, it) then
		out[#out + 1] = { "s", "split into steps" }
		out[#out + 1] = { "d", "new date" }
	elseif it.late > 0 and not it.step_of then
		out[#out + 1] = { "t", "do today" }
		out[#out + 1] = { "d", "new date" }
	elseif not lib.remaining(m, it) and not it.recurring then
		out[#out + 1] = { "e", "estimate" }
	end
	out[#out + 1] = { "x", "done" }
	return out
end

--- True for a one-off A task without steps that is SLIP_DAYS past due or
--- was moved SLIP_MOVES times. Adding steps clears it.
function lib.slipping(m, it)
	if it.rating ~= "A" or it.recurring or (m.steps[it.id] and #m.steps[it.id] > 0) then
		return false
	end
	return it.late >= SLIP_DAYS or it.moves >= SLIP_MOVES
end

--- The Attention items, most important first, each { key, text, id }. A key
--- snoozed today is left out. `review_due` adds the daily review prompt.
--- `proposals` maps a task ID to Claude's report that the task is done, as
--- { note }; each open one comes first, for the user to confirm or reject.
function lib.attention(m, review_due, snoozed, proposals)
	local items = {}
	local function add(key, text, id, proposal)
		if not (snoozed and snoozed[key] == m.today) then
			items[#items + 1] = { key = key, text = text, id = id, proposal = proposal }
		end
	end
	for _, it in ipairs(sorted(m.open)) do
		local p = proposals and proposals[it.id]
		if p then
			local note = (p.note or "") ~= "" and (": " .. p.note) or "."
			add("done " .. it.id, "Claude reports done: " .. it.name .. note, it.id, true)
		end
	end
	if review_due then
		add("review", "Daily review due · press v")
	end
	local open = sorted(m.open)
	for _, it in ipairs(open) do
		if lib.slipping(m, it) then
			local why = it.late >= SLIP_DAYS and (it.late .. "d past") or ("moved " .. it.moves .. " times")
			local ask = not STEPS and "Set a new date." or lib.too_large(m, it) and "Split it into steps." or "Split it into steps or set a new date."
			add("slip " .. it.id, it.name .. ": " .. why .. ". " .. ask, it.id)
		end
	end
	local today_load = lib.load(m, lib.today_items(m), TODAY_LIMIT)
	if today_load > CAPACITY then
		add("today load", "Today holds " .. lib.format_minutes(today_load) .. " of work, more than "
			.. lib.format_minutes(CAPACITY) .. ". Move some to a later day.")
	end
	local a_load = lib.load(m, lib.a_items(m), A_LIMIT)
	if a_load > CAPACITY then
		add("A load", "A work totals " .. lib.format_minutes(a_load) .. ", more than one day ("
			.. lib.format_minutes(CAPACITY) .. "). Rate some B.")
	end
	for _, it in ipairs(open) do
		if lib.too_large(m, it) and not lib.slipping(m, it) then
			local why = it.estimate and ("estimated " .. lib.format_minutes(it.estimate)) or (it.late .. "d past, no estimate")
			add("split " .. it.id, it.name .. ": " .. why .. ". Split it into steps of at most " .. lib.format_minutes(SPLIT_MINUTES) .. ".", it.id)
		end
	end
	return items
end

--- The review record after a review on `today`: the streak grows when the
--- last review was yesterday and starts again at 1 otherwise.
function lib.finish_review(review, today)
	review = review or {}
	if review.last == today then
		return review
	end
	local streak = review.last == lib.add_days(today, -1) and (review.streak or 0) + 1 or 1
	return { last = today, streak = streak }
end

--- The streak as it stands today: 0 once a day passed without a review.
function lib.streak(review, today)
	review = review or {}
	if review.last == today or review.last == lib.add_days(today, -1) then
		return review.streak or 0
	end
	return 0
end

--- A due date as shown: "today", "tomorrow", "Mon 23" within a week, "30 Nov"
--- later, or "2d past" with true as the second value.
function lib.due_label(due, today)
	if not due then
		return nil
	end
	local n = lib.days_between(today, due)
	if n < 0 then
		return -n .. "d past", true
	elseif n == 0 then
		return "today"
	elseif n == 1 then
		return "tomorrow"
	elseif n < 7 then
		return lib.day_text(due)
	end
	local t = os.date("*t", noon(due))
	return t.day .. " " .. months[t.month]
end

local state = {
	--- The lists from the last refresh, each with its open and completed tasks.
	lists = nil,
	signed_out = false,
	--- The detail of the last sign-in answer, such as "sign-in expired", or nil.
	sign_in_detail = nil,
	--- True when the provider answered that it is not set up.
	setup_needed = false,
	--- Lines about the last failed fetch and the last failed write, or nil.
	fetch_notice = nil,
	write_notice = nil,
	--- The selected task's ID.
	selected = nil,
	--- "now", "today", "all" or "review".
	view = "now",
	--- The text being typed: { kind, text, id, error, advance }, or nil.
	input = nil,
	--- The list picker: { kind = "lists" or "move", index, id }, or nil.
	picker = nil,
	--- The daily review in progress: { stage, ids, index, confirm }, or nil.
	review = nil,
	--- True while the list of keys is shown.
	help = false,
	--- A line on the last key, when it did nothing on the screen shown.
	key_notice = nil,
	--- The Attention item shown, counted from 1.
	attention = 1,
	--- The day a key was last pressed in this tab.
	key_day = nil,
	--- The contents of the state file as last read or written.
	saved = nil,
	--- The state file's changed_at at the last fetch, and the time of that fetch.
	seen_change = nil,
	fetched_at = nil,
	--- Raised by each write, so that a fetch started before it is discarded.
	generation = 0,
	--- A fixed date for tests, in place of the clock.
	clock = nil,
}

local function today()
	return state.clock or os.date("%Y-%m-%d")
end

local function read_state()
	return providers.read_state(sidecar.settings_dir, config.state_file)
end

--- Reads the state file, applies `change` and writes it back. The file is
--- read first because other panes and the task actions write it too.
local function change_state(change)
	local s = read_state()
	change(s)
	providers.write_state(sidecar.settings_dir, s, config.state_file)
	state.saved = s
end

local function saved()
	state.saved = state.saved or read_state()
	return state.saved
end

--- The lists the tab shows: all but those hidden with l.
local function shown_lists()
	local hidden = LISTS and saved().hidden_lists
	if not (state.lists and type(hidden) == "table") then
		return state.lists
	end
	local out = {}
	for _, list in ipairs(state.lists) do
		if not hidden[list.id] then
			out[#out + 1] = list
		end
	end
	return out
end

--- The list chosen with l for new tasks, while it exists and is shown.
local function default_list()
	local id = LISTS and saved().default_list
	local hidden = saved().hidden_lists
	if type(hidden) == "table" and id and hidden[id] then
		return nil
	end
	for _, list in ipairs(id and state.lists or {}) do
		if list.id == id then
			return list
		end
	end
end

local function model()
	return lib.model(shown_lists(), today(), saved().moves)
end

--- The tab's provider.
local function provider()
	return config.provider
end

--- The day of the last prompt in the Claude transcript the pane follows.
local function last_prompt_day()
	local panel = sidecar.panel
	local prompts = panel and panel.state and panel.state.prompts
	local last = prompts and prompts[#prompts]
	local at = last and sidecar.epoch and sidecar.epoch(last.at)
	return at and os.date("%Y-%m-%d", at) or nil
end

--- True when today's review is not done and the user was active today: a key
--- in this tab or a prompt to Claude. Once seen, the prompt is saved for the
--- day, so every pane shows it.
local function review_due()
	local s, day = saved(), today()
	if s.review.last == day then
		return false
	end
	return s.prompted == day or state.key_day == day or last_prompt_day() == day
end

--- Saves that the review prompt was shown today.
local function note_prompt()
	local day = today()
	if review_due() and saved().prompted ~= day then
		change_state(function(s)
			s.prompted = day
		end)
	end
end

--- Counts due-date changes of open tasks between refreshes, forgets closed
--- tasks, and drops snoozes from earlier days.
local function note_moves(lists)
	change_state(function(s)
		local seen = {}
		for _, list in ipairs(lists) do
			for _, t in ipairs(list.tasks or {}) do
				local due = t.due or ""
				if t.status ~= "completed" then
					-- A first date is not a move, and neither is a cleared one.
					local before = s.dues[t.id]
					if before and before ~= "" and due ~= "" and before ~= due then
						s.moves[t.id] = (s.moves[t.id] or 0) + 1
					end
					s.dues[t.id], seen[t.id] = due, true
				end
			end
		end
		for _, field in ipairs({ "dues", "moves" }) do
			for id in pairs(s[field]) do
				if not seen[id] then
					s[field][id] = nil
				end
			end
		end
		for key, day in pairs(s.snoozed) do
			if day ~= today() then
				s.snoozed[key] = nil
			end
		end
		for id in pairs(s.proposals) do
			if not seen[id] then
				s.proposals[id] = nil
			end
		end
	end)
end

--- The Attention items for the model, with the review prompt and Claude's
--- reports from the state file.
local function attention_items(m)
	return lib.attention(m, review_due(), saved().snoozed, saved().proposals)
end

--- The Attention item shown, or nil.
local function attention_item(m)
	local items = attention_items(m)
	return items[math.min(state.attention, #items)], #items
end

--- Runs the provider with the given arguments; only inside a task, where it
--- doesn't stop the pane.
local function client_run(limit, ...)
	return sidecar.run({ providers.command(sidecar.dir, provider()), ... }, limit)
end

--- The first line of a command's error output, or else of its output, for a notice.
local function first_line(r)
	if not r then
		return "no answer"
	end
	local text = (r.stderr or "") ~= "" and r.stderr or (r.stdout or "")
	return text:match("[^\n]+") or "no answer"
end

local queue = {}

--- Fetches the lists. A fetch that a write overtook is discarded, as the
--- write's own fetch follows.
local function fetch()
	local generation = state.generation
	local r = client_run(30, "tasks", "--completed-since", lib.add_days(today(), -HISTORY_DAYS))
	local ok, data = pcall(rex.json.decode, r and r.stdout or "")
	if r and r.code == 4 then
		state.setup_needed, state.signed_out = true, false
	elseif r and (r.code == 3 or ok and type(data) == "table" and data.error == "auth_required") then
		state.signed_out, state.setup_needed = true, false
		state.sign_in_detail = ok and type(data) == "table" and data.detail or nil
	elseif r and r.ok and ok and type(data) == "table" then
		if generation ~= state.generation or #queue > 0 then
			return
		end
		state.lists, state.signed_out, state.setup_needed, state.fetch_notice = data, false, false, nil
		note_moves(data)
	else
		state.setup_needed = false
		state.fetch_notice = "Tasks: " .. first_line(r)
	end
end

--- Runs `op`, a function that runs the client and returns its result, after
--- the writes before it, then fetches the lists once the queue is empty.
local function enqueue(label, op)
	queue[#queue + 1] = { label = label, op = op }
	state.generation = state.generation + 1
	sidecar.spawn("tasks write", function()
		repeat
			while #queue > 0 do
				local entry = table.remove(queue, 1)
				local r = entry.op()
				-- A fetch that started while this write ran holds older data.
				state.generation = state.generation + 1
				if r and r.ok then
					state.write_notice = nil
				else
					state.write_notice = entry.label .. " failed: " .. first_line(r)
				end
			end
			fetch()
		until #queue == 0
	end)
end

--- Reads the state file and saves a review prompt seen in the transcript.
--- Fetches the lists once FETCH_SECONDS pass, or at once when a task action
--- recorded a change.
local function refresh_all()
	state.saved = read_state()
	note_prompt()
	local changed = state.saved.changed_at ~= state.seen_change
	if changed or os.time() - (state.fetched_at or 0) >= FETCH_SECONDS then
		state.seen_change, state.fetched_at = state.saved.changed_at, os.time()
		fetch()
	end
end

--- The open task with an ID, and its list.
local function find_task(id)
	for _, list in ipairs(state.lists or {}) do
		for _, t in ipairs(list.tasks or {}) do
			if t.id == id and t.status ~= "completed" then
				return t, list
			end
		end
	end
end

--- Changes fields of a task at once, and through the provider in the background.
--- `fields` holds title, due ("" clears it), notes or status.
local function update(id, fields, label)
	local t, list = find_task(id)
	if not t or t.pending then
		return
	end
	local argv = { "update", list.id, id }
	for _, key in ipairs({ "title", "due", "notes", "status", "priority" }) do
		if fields[key] then
			t[key] = fields[key]
			argv[#argv + 1] = "--" .. key
			argv[#argv + 1] = fields[key]
		end
	end
	if t.priority == "none" then
		t.priority = nil
	end
	enqueue(label, function()
		return client_run(30, unpack(argv))
	end)
end

--- Marks a task done, or dropped: completed with DROP_NOTE added to its notes.
local function complete(id, drop)
	local t = find_task(id)
	if not t or t.pending then
		return
	end
	local fields = { status = "completed" }
	if drop then
		fields.notes = (t.notes or "") ~= "" and (t.notes .. "\n" .. DROP_NOTE) or DROP_NOTE
	end
	update(id, fields, drop and "Dropping the task" or "Marking the task done")
	t.completed = today()
	-- Steps are completed with their task, as not every provider does it.
	for _, list in ipairs(state.lists or {}) do
		for _, step in ipairs(list.tasks or {}) do
			if step.parent == id and step.status ~= "completed" and not step.pending then
				update(step.id, { status = "completed" }, "Marking the step done")
				step.completed = today()
			end
		end
	end
end

--- Marks a task completed today as not done, at once and through the
--- provider in the background.
local function reopen(id)
	for _, list in ipairs(state.lists or {}) do
		for _, t in ipairs(list.tasks or {}) do
			if t.id == id and t.status == "completed" and not t.pending then
				t.status, t.completed = "needsAction", nil
				enqueue("Marking the task not done", function()
					return client_run(30, "update", list.id, id, "--status", "needsAction")
				end)
				return
			end
		end
	end
end

--- Sets the rating or the estimate in a task's title; `field` is "rating"
--- or "estimate", and a nil value removes it.
local function retitle(id, field, value, label)
	local t = find_task(id)
	if not t then
		return
	end
	local p = lib.parse_title(t.title or "")
	if PRIORITY then
		-- The rating goes to the priority field, and a prefix left in the
		-- title from before goes with it.
		local rating = lib.rating_of(t, p)
		if field == "rating" then
			rating = value
		else
			p[field] = value
		end
		update(id, { title = lib.compose_title(nil, p.name, p.estimate), priority = rating or "none" }, label)
		return
	end
	p[field] = value
	update(id, { title = lib.compose_title(p.rating, p.name, p.estimate) }, label)
end

local pending_count = 0

--- Adds a task at once, shown dim, and through the provider in the background. A
--- step goes after `previous`, a task table whose ID is read when the write
--- runs, by which time the writes before it have given it its real ID.
local function add_task(list, title, due, parent, previous)
	pending_count = pending_count + 1
	local priority
	if PRIORITY then
		local p = lib.parse_title(title)
		title, priority = lib.compose_title(nil, p.name, p.estimate), p.rating
	end
	local t = { id = "pending " .. pending_count, title = title, due = due or "", parent = parent and parent.id,
		status = "needsAction", pending = true, priority = priority }
	local at, after = 1, previous or parent
	for i, x in ipairs(list.tasks) do
		if x == after then
			at = i + 1
		end
	end
	table.insert(list.tasks, at, t)
	enqueue("Adding the task", function()
		local argv = { "add", list.id }
		if due and due ~= "" then
			argv[#argv + 1], argv[#argv + 2] = "--due", due
		end
		if parent then
			argv[#argv + 1], argv[#argv + 2] = "--parent", parent.id
		end
		if previous and not previous.pending then
			argv[#argv + 1], argv[#argv + 2] = "--previous", previous.id
		end
		if priority then
			argv[#argv + 1], argv[#argv + 2] = "--priority", priority
		end
		argv[#argv + 1] = title
		local r = client_run(30, unpack(argv))
		local ok, data = pcall(rex.json.decode, r and r.stdout or "")
		if r and r.ok and ok and type(data) == "table" and data.id then
			if state.selected == t.id then
				state.selected = data.id
			end
			t.id, t.pending = data.id, nil
		end
		return r
	end)
	return t
end

--- Moves the state file's records of a task to its new ID.
local function rekey(s, old, new)
	for _, field in ipairs({ "dues", "moves", "proposals" }) do
		s[field][new], s[field][old] = s[field][old], nil
	end
	for key, day in pairs(s.snoozed) do
		local kind = key:match("^(%S+) " .. old:gsub("%p", "%%%0") .. "$")
		if kind then
			s.snoozed[kind .. " " .. new], s.snoozed[key] = day, nil
		end
	end
end

--- Moves a task to another list, at once and through the provider in the
--- background. The moved task gets a new ID, which the state file follows.
local function move_task(id, to)
	local t, from = find_task(id)
	if not t or t.pending or not to or from == to then
		return
	end
	for i, x in ipairs(from.tasks) do
		if x == t then
			table.remove(from.tasks, i)
			break
		end
	end
	to.tasks[#to.tasks + 1] = t
	t.pending = true
	enqueue("Moving the task", function()
		local r = client_run(30, "move", from.id, id, to.id)
		local ok, data = pcall(rex.json.decode, r and r.stdout or "")
		if r and r.ok and ok and type(data) == "table" and data.id then
			if state.selected == id then
				state.selected = data.id
			end
			t.id, t.pending = data.id, nil
			change_state(function(s)
				rekey(s, id, data.id)
			end)
		end
		return r
	end)
end

--- Opens the list picker: "lists" to choose the lists shown and the default
--- one, "move" to move task `it`, starting at its own list.
local function open_picker(kind, it)
	state.picker = { kind = kind, index = 1, id = it and it.id }
	local list
	if it then
		list = select(2, find_task(it.id))
	end
	for i, l in ipairs(state.lists or {}) do
		if l == list then
			state.picker.index = i
		end
	end
end

--- Acts on the picker's list at `index`: shows or hides it, makes it the
--- default, or moves the task to it.
local function pick(index, how)
	local p, list = state.picker, (state.lists or {})[index]
	if not (p and list) then
		return
	end
	p.index = index
	if p.kind == "move" then
		move_task(p.id, list)
		state.picker = nil
	elseif how == "default" then
		-- A new task must land where it can be seen, so the default is shown.
		change_state(function(s)
			s.default_list = list.id
			if type(s.hidden_lists) == "table" then
				s.hidden_lists[list.id] = nil
			end
		end)
	else
		local hidden = type(saved().hidden_lists) == "table" and saved().hidden_lists or {}
		if not hidden[list.id] and #shown_lists() <= 1 then
			state.key_notice = "At least one list stays shown."
			return
		end
		change_state(function(s)
			s.hidden_lists = type(s.hidden_lists) == "table" and s.hidden_lists or {}
			s.hidden_lists[list.id] = not s.hidden_lists[list.id] or nil
		end)
	end
end

--- Keys while the picker is open: j and k select a list, Space shows or
--- hides it, d makes it the default, Enter moves the task or closes, and
--- Escape closes.
local function picker_key(k)
	local p, count = state.picker, #(state.lists or {})
	if k == "escape" or ((k == "\r" or k == "\n" or k == "l") and p.kind == "lists") then
		state.picker = nil
	elseif k == "j" or k == "down" then
		p.index = math.min(count, p.index + 1)
	elseif k == "k" or k == "up" then
		p.index = math.max(1, p.index - 1)
	elseif p.kind == "lists" and (k == " " or k == "d") then
		pick(p.index, k == "d" and "default")
	elseif p.kind == "move" and (k == "\r" or k == "\n") then
		pick(p.index)
	end
	return true
end

local function start_review()
	local ids = {}
	for _, it in ipairs(lib.late_items(model())) do
		ids[#ids + 1] = it.id
	end
	state.review = { stage = "late", ids = ids, index = 1 }
	state.view, state.input = "review", nil
end

--- The task the review's first stage shows, skipping those closed meanwhile.
local function review_item(m)
	local r = state.review
	while r.stage == "late" and r.index <= #r.ids do
		local it = m.by[r.ids[r.index]]
		if it then
			return it
		end
		r.index = r.index + 1
	end
end

--- Moves the review on: to the next late task, then to the A limit when A
--- work exceeds a day, then to today's list.
local function advance()
	local r = state.review
	if not r then
		return
	end
	r.confirm = false
	local m = model()
	if r.stage == "late" then
		r.index = r.index + 1
		if review_item(m) then
			return
		end
		r.stage = lib.load(m, lib.a_items(m), A_LIMIT) > CAPACITY and "limit" or "today"
	elseif r.stage == "limit" then
		r.stage = "today"
	end
	state.selected = nil
end

local function finish_review()
	local day = today()
	change_state(function(s)
		s.review = lib.finish_review(s.review, day)
	end)
	state.review, state.view, state.selected = nil, "now", nil
end

--- The selectable rows of the open view, each { item, depth }: a task, and the
--- first open step under it, or all its steps in the All view.
local function rows_of(m)
	local rows = {}
	local function add(it, all_steps)
		rows[#rows + 1] = { item = it, depth = 0 }
		for i, s in ipairs(m.steps[it.id] or {}) do
			if i > 1 and not all_steps then
				break
			end
			rows[#rows + 1] = { item = s, depth = 1 }
		end
	end
	local view, r = state.view, state.review
	if view == "now" or view == "today" or (r and r.stage == "today") then
		for _, it in ipairs(m.done) do
			rows[#rows + 1] = { item = it, depth = 0 }
		end
		for _, it in ipairs(lib.today_items(m)) do
			add(it)
		end
	end
	if view == "today" then
		for _, it in ipairs(sorted(m.open)) do
			if it.due and it.due > m.today and it.due <= lib.add_days(m.today, 7) then
				add(it)
			end
		end
	elseif view == "all" then
		for _, it in ipairs(sorted(m.open)) do
			add(it, true)
		end
	elseif r and r.stage == "limit" then
		for _, it in ipairs(lib.a_items(m)) do
			rows[#rows + 1] = { item = it, depth = 0 }
		end
	end
	return rows
end

--- The rows of the view whose task, or for a step the task it belongs to,
--- passes `keep`.
local function rows_where(m, keep)
	local out = {}
	for _, row in ipairs(rows_of(m)) do
		if keep(row.item.step_of or row.item) then
			out[#out + 1] = row
		end
	end
	return out
end

--- The index of the selected row. With none selected, the Now view selects
--- the Next task, so that the keys shown for the selection apply to it, and
--- the other views select the first row.
local function selected_index(rows, m)
	for i, r in ipairs(rows) do
		if r.item.id == state.selected then
			return i
		end
	end
	local preferred = state.view == "now" and lib.next_item(m)
	for i, r in ipairs(rows) do
		if preferred and r.item.id == preferred.id then
			state.selected = r.item.id
			return i
		end
	end
	state.selected = rows[1] and rows[1].item.id
	return rows[1] and 1
end

--- Completes a task and selects the row that takes its place, so that the
--- selection never jumps to the top of the list.
local function complete_row(id, drop)
	local done = model().by[id]
	if done and done.done then
		reopen(id)
		return
	end
	-- Done rows sit at the top, so the next row is counted among open ones.
	local function open_rows()
		local out = {}
		for _, r in ipairs(rows_of(model())) do
			if not r.item.done then
				out[#out + 1] = r
			end
		end
		return out
	end
	local at = 1
	for i, r in ipairs(open_rows()) do
		if r.item.id == id then
			at = i
		end
	end
	complete(id, drop)
	local rest = open_rows()
	local row = rest[math.min(at, #rest)]
	state.selected = row and row.item.id
end

--- Accepts or rejects Claude's report that a task is done.
local function settle_proposal(id, accept)
	change_state(function(s)
		s.proposals[id] = nil
	end)
	if accept then
		complete_row(id)
	end
end

--- The task that keys act on: in the review's first stage its task, else the
--- selected row.
local function target(m)
	if state.review and state.review.stage == "late" then
		return review_item(m)
	end
	local rows = rows_of(m)
	local at = selected_index(rows, m)
	return at and rows[at].item
end

local input_hints = {
	add = "A. Title (20m) fri · Enter adds · Esc cancels",
	edit = "A. Title (20m), and a date last to change it · Enter saves · Esc cancels",
	date = "today, tomorrow, mon, +3, 2026-12-01; empty clears",
	estimate = "15m, 1h, 1h30; empty clears",
	steps = "One step of at most 2h, as Title (30m) · Enter adds · Esc finishes",
}

local function open_input(kind, it)
	-- A new date or new steps decide a task in the review's first stage.
	local deciding = state.review ~= nil and state.review.stage == "late" and (kind == "date" or kind == "steps")
	state.input = { kind = kind, text = "", id = it and it.id, advance = deciding }
	if kind == "edit" then
		state.input.text = lib.compose_title(it.rating, it.name, it.estimate)
	end
end

--- Acts on the typed text. Returns false to keep the input open.
local function commit(input)
	local text, day = trim(input.text), today()
	if input.kind == "add" then
		if text == "" then
			return true
		end
		local m = model()
		local selected = m.by[state.selected or ""]
		local list = default_list() or selected and selected.list or (shown_lists() or {})[1]
		if not list then
			return true
		end
		local title, due = lib.parse_entry(text, day)
		if not due and state.view ~= "all" then
			due = day
		end
		state.selected = add_task(list, title, due).id
	elseif input.kind == "edit" then
		if text == "" then
			input.error = "A task needs a title."
			return false
		end
		local title, due = lib.parse_entry(text, day)
		local fields = { due = due }
		if PRIORITY then
			local p = lib.parse_title(title)
			fields.title, fields.priority = lib.compose_title(nil, p.name, p.estimate), p.rating or "none"
		else
			fields.title = title
		end
		update(input.id, fields, "Editing the task")
	elseif input.kind == "date" then
		local due = lib.parse_date(text, day)
		if not due then
			input.error = "Not a date: " .. text
			return false
		end
		update(input.id, { due = due }, "Setting the date")
	elseif input.kind == "estimate" then
		local minutes = text ~= "" and lib.parse_estimate(text)
		if text ~= "" and not minutes then
			input.error = "Not an estimate: " .. text
			return false
		end
		retitle(input.id, "estimate", minutes or nil, "Setting the estimate")
	elseif input.kind == "steps" then
		if text == "" then
			return true
		end
		local parent, list = find_task(input.id)
		if parent then
			local title, due = lib.parse_entry(text, day)
			local m = model()
			local steps = m.steps[input.id] or {}
			local last = steps[#steps]
			input.previous = add_task(list, title, due, parent, input.previous or (last and last.task))
		end
		input.text, input.error = "", nil
		return false
	end
	return true
end

--- Keys while text is typed: Enter commits, Escape closes, and Backspace
--- removes a whole character.
local function input_key(k)
	local input = state.input
	if k == "\r" or k == "\n" then
		if commit(input) then
			state.input = nil
			if input.advance and (input.kind == "date" or input.previous) then
				advance()
			end
		end
	elseif k == "escape" then
		state.input = nil
		if input.kind == "steps" and input.previous and input.advance then
			advance()
		end
	elseif k == "\127" or k == "\8" then
		input.text = input.text:gsub("[^\128-\191][\128-\191]*$", "")
	elseif #k == 1 and k:byte() >= 32 then
		input.text, input.error = input.text .. k, nil
	end
	return true
end

local views = { "now", "today", "all" }

--- The keys on the Attention item, which the Now view shows: z hides it
--- until tomorrow, ] shows the next, Enter selects its task, and y or n
--- settles a report.
local function attention_key(k, m)
	local item, count = attention_item(m)
	if state.view ~= "now" or not item then
		return false
	elseif k == "z" then
		change_state(function(s)
			s.snoozed[item.key] = m.today
		end)
		return true
	elseif k == "]" then
		state.attention = state.attention % count + 1
		return count > 1
	elseif not item.id then
		return false
	elseif k == "\r" or k == "\n" then
		state.selected = item.id
		return true
	elseif not item.proposal then
		return false
	end
	settle_proposal(item.id, k == "y")
	return true
end

--- The keys that act on a task, in every view.
local function task_key(k, it, m)
	if not it or it.pending then
		return false
	elseif it.done then
		if k == "x" then
			reopen(it.id)
			return true
		end
		return false
	end
	local in_review = state.review and state.review.stage == "late"
	if k == "x" then
		complete_row(it.id)
	elseif k == "A" or k == "B" or k == "C" then
		retitle(it.id, "rating", k, "Rating the task")
	elseif k == "t" then
		update(it.id, { due = m.today }, "Planning the task for today")
	elseif k == "d" then
		open_input("date", it)
		return true
	elseif k == "e" then
		open_input("estimate", it)
		return true
	elseif k == "E" then
		open_input("edit", it)
		return true
	elseif k == "s" and STEPS then
		open_input("steps", it.step_of or it)
		return true
	elseif k == "m" and LISTS then
		open_picker("move", it)
		return true
	else
		return false
	end
	if in_review then
		advance()
	end
	return true
end

local function review_key(k, m)
	local r = state.review
	if k == "escape" then
		state.review, state.view = nil, "now"
		return true
	end
	if r.stage == "late" then
		local it = review_item(m)
		if r.confirm then
			if k == "y" and it then
				complete(it.id, true)
			end
			r.confirm = false
			if k == "y" then
				advance()
			end
			return true
		end
		if k == "-" then
			r.confirm = true
			return true
		elseif k == "]" or not it then
			advance()
			return true
		end
		return task_key(k, it, m)
	end
	if k == "\r" or k == "\n" or k == "]" then
		if r.stage == "today" then
			finish_review()
		else
			advance()
		end
		return true
	end
	return false
end

local tab = { name = config.name, interval = 5, hidden = true, lib = lib, state = state }

tab.refresh = refresh_all

function tab.activate()
	state.saved = read_state()
end

local function handle(k)
	local day = today()
	if state.key_day ~= day then
		state.key_day = day
		note_prompt()
	end
	if state.input then
		return input_key(k)
	end
	if state.picker then
		return picker_key(k)
	end
	if k == "r" then
		state.fetched_at = nil
		sidecar.spawn("tasks refresh", refresh_all)
		return true
	end
	if state.signed_out or state.setup_needed then
		if k == "L" then
			state.fetch_notice = provider() == "apple" and "Asking macOS for access to Reminders…" or "Signing in through the browser…"
			sidecar.spawn("tasks login", function()
				-- The provider waits 300 seconds for the browser and then names the likely cause.
				local r = client_run(330, "login")
				state.fetch_notice = not (r and r.ok) and (r and first_line(r) or "Sign-in failed: no answer within 5 minutes.") or nil
				fetch()
			end)
		end
		return k == "L"
	end
	if not state.lists then
		return false
	end
	local m = model()
	if k == "?" or (k == "escape" and state.help) then
		state.help = k == "?" and not state.help
		return true
	end
	if k == "v" then
		start_review()
		return true
	elseif k == "l" and LISTS then
		open_picker("lists")
		return true
	end
	if state.review then
		if review_key(k, m) then
			return true
		end
	elseif k == "V" then
		for i, v in ipairs(views) do
			if v == state.view then
				state.view = views[i % #views + 1]
				break
			end
		end
		return true
	elseif k == "y" or k == "n" or k == "z" or k == "]" or k == "\r" or k == "\n" then
		return attention_key(k, m)
	end
	local rows = rows_of(m)
	local at = selected_index(rows, m)
	if at and (k == "j" or k == "down" or k == "k" or k == "up") then
		local step = (k == "j" or k == "down") and 1 or -1
		state.selected = rows[math.max(1, math.min(#rows, at + step))].item.id
		return true
	elseif k == "a" then
		open_input("add")
		return true
	end
	return task_key(k, target(m), m)
end

--- The keys this tab uses somewhere; one that does nothing on the screen
--- shown gets a notice instead of no answer.
local tab_keys = {}
for k in ((STEPS and "s" or "") .. (LISTS and "lm" or "") .. "xtdeEaABCvVz]yn-Lrjk"):gmatch(".") do
	tab_keys[k] = true
end
local task_keys = { x = true, t = true, d = true, e = true, E = true, s = STEPS or nil, m = LISTS or nil, A = true, B = true, C = true }
local unused_notices = {
	z = "z hides warnings; use d to move a task to a later date.",
	["]"] = "] shows the next warning; there is no other one here.",
	y = "y and n answer a report that a task is done; there is none here.",
	n = "y and n answer a report that a task is done; there is none here.",
	["-"] = "- drops a task in the daily review; v starts it.",
	L = "L signs in when the tab asks for it.",
	j = "There are no other tasks here to select.",
	k = "There are no other tasks here to select.",
}

--- The notice for a key of this tab that does nothing on the screen shown.
local function unused_notice(k)
	if task_keys[k] then
		local it = target(model())
		return it and it.pending and "The task is still being saved." or "No task selected: j and k select one."
	end
	return unused_notices[k] or (k .. " does nothing on this screen; ? lists the keys that do.")
end

function tab.key(k)
	state.key_notice = nil
	if handle(k) then
		return true
	end
	if not (tab_keys[k] and state.lists and not state.signed_out and not state.setup_needed) then
		return false
	end
	state.key_notice = unused_notice(k)
	return true
end

function tab.act(action)
	if action.kind == "view" then
		state.view, state.review, state.input = action.view, nil, nil
	elseif action.kind == "select" then
		state.selected = action.id
	elseif action.kind == "done" then
		complete_row(action.id)
	elseif action.kind == "pick" then
		pick(action.index)
	end
end

function tab.badge()
	if not state.lists or state.signed_out or state.setup_needed then
		return nil
	end
	local m = model()
	local alert = review_due() or next(saved().proposals) ~= nil
	for _, it in ipairs(m.open) do
		alert = alert or lib.slipping(m, it)
	end
	local n = #lib.today_items(m)
	return n .. (alert and "!" or "")
end

local rating_colour = { A = c.bold .. c.orange, B = c.yellow, C = c.grey }

--- A name clipped to n columns, with an ellipsis when cut.
local function fit(s, n)
	if width(s) <= n then
		return s
	end
	return clip(s, math.max(0, n - 1)) .. "…"
end

--- A name as shown: recurring tasks in teal with a repeat mark.
local function shown_name(it, room)
	if it.recurring and not it.done then
		return c.teal .. fit(it.name, room - 2) .. " ↻" .. c.reset
	end
	return (it.done or it.pending) and (c.dim .. fit(it.name, room) .. c.reset) or fit(it.name, room)
end

--- The rating letter, coloured, and a space; two spaces for none.
local function rating_mark(it)
	return it.rating and (rating_colour[it.rating] .. it.rating .. c.reset .. " ") or "  "
end

--- A row: selection mark, indent, the circle a click completes, the rating,
--- the name, and at the right the estimate (from 40 columns) and the date.
local function row_line(m, row, cols, selected)
	local it = row.item
	local indent = string.rep("  ", row.depth)
	local due, late = lib.due_label(it.due, m.today)
	if it.done then
		due = "done"
	elseif row.depth > 0 and not it.due then
		due = nil
	end
	local est = cols >= 40 and (lib.remaining(m, it) or (it.done and it.estimate)) or nil
	local right = (est and lib.format_minutes(est) or "")
	if due then
		local label = (late and c.orange or c.dim) .. due .. c.reset
		right = right ~= "" and (c.dim .. right .. c.reset .. "  " .. label) or label
	elseif right ~= "" then
		right = c.dim .. right .. c.reset
	end
	local mark = selected and (c.cyan .. "› " .. c.reset) or "  "
	local circle = it.done and (c.green .. "✓" .. c.reset) or (c.grey .. "○" .. c.reset)
	local left = mark .. indent .. circle .. " " .. rating_mark(it)
	local room = cols - width(left) - (right ~= "" and width(right) + 1 or 0)
	left = left .. shown_name(it, math.max(4, room))
	local line = left .. string.rep(" ", math.max(1, cols - width(left) - width(right))) .. right
	local circle_at = 3 + #indent
	local action = { ranges = {
		{ from = circle_at, to = circle_at, action = { kind = "done", id = it.id } },
		{ from = 1, to = cols, action = { kind = "select", id = it.id } },
	} }
	return line, action
end

--- Words joined by `sep`, two spaces by default, into lines of n columns.
local function flow(parts, n, sep)
	sep = sep or "  "
	local out, line = {}, ""
	for _, part in ipairs(parts) do
		if line ~= "" and width(line) + width(sep) + width(part) > n then
			out[#out + 1] = line
			line = part
		else
			line = line ~= "" and (line .. sep .. part) or part
		end
	end
	if line ~= "" then
		out[#out + 1] = line
	end
	return out
end

--- Builds a view: lines, the click per line and the selected line.
local function new_view()
	local v = { lines = {}, actions = {} }
	function v.add(line, action)
		v.lines[#v.lines + 1] = line
		v.actions[#v.lines] = action
	end
	function v.dim(text, n)
		for _, l in ipairs(sidecar.wrap(text, n, "", "")) do
			v.add(c.dim .. l .. c.reset)
		end
	end
	function v.hints(parts, n)
		for _, l in ipairs(flow(parts, n, " · ")) do
			v.add(c.dim .. l .. c.reset)
		end
	end
	function v.box(colour, title, right, body)
		sidecar.box(v.lines, v.actions, v.cols, colour, c.bold .. colour .. title .. c.reset, right and (c.dim .. right .. c.reset) or "", body)
	end
	return v
end

local function add_rows(v, m, rows, n)
	for _, row in ipairs(rows) do
		local line, action = row_line(m, row, n, row.item.id == state.selected and not state.input)
		v.add(line, action)
		if row.item.id == state.selected then
			v.selected = #v.lines
		end
	end
end

--- The input box: what is typed, and a hint on what it accepts.
local function input_box(v, m)
	local input = state.input
	local it = input.id and m.by[input.id]
	local titles = { add = "New task", edit = "Edit task", date = "New date", estimate = "Estimate", steps = "Steps" }
	v.box(c.cyan, titles[input.kind] .. (it and (" · " .. it.name) or ""), nil, function(n)
		if input.kind == "steps" then
			local long = false
			for i, s in ipairs(m.steps[input.id] or {}) do
				local est = s.estimate and lib.format_minutes(s.estimate) or ""
				local over = s.estimate and s.estimate > SPLIT_MINUTES
				long = long or over
				local name = fit(i .. " " .. s.name, n - width(est) - 1)
				v.add(name .. string.rep(" ", math.max(1, n - width(name) - width(est))) .. (over and c.orange or c.dim) .. est .. c.reset)
			end
			if long then
				v.add(c.orange .. fit("A step over " .. lib.format_minutes(SPLIT_MINUTES) .. " is to be split further.", n) .. c.reset)
			end
		end
		-- Text longer than the line shows its end, where the typing is.
		local text = input.text
		while width(text) > n - 3 do
			text = text:gsub("^[^\128-\191][\128-\191]*", "")
		end
		v.add(c.cyan .. "› " .. c.reset .. text .. "▏")
		v.selected = #v.lines
		if input.error then
			v.add(c.orange .. fit(input.error, n) .. c.reset)
		end
		v.dim(input_hints[input.kind], n)
	end)
end

--- The progress line: a bar where it fits, and "N of M done · time left".
local function progress(m, items, n)
	local done = #m.done
	local total = done + #items
	local left, unknown = lib.time_left(m, items)
	local text = done .. " of " .. total .. " done"
	if left > 0 then
		text = text .. " · " .. lib.format_minutes(left) .. " left"
	end
	if unknown > 0 then
		text = text .. " · " .. unknown .. " no est"
	end
	local bar = n - width(text) - 1
	if bar < 6 then
		return fit(text, n)
	end
	local filled = total > 0 and math.floor(bar * done / total + 0.5) or 0
	return c.green .. string.rep("█", filled) .. c.grey .. string.rep("░", bar - filled) .. c.reset .. " " .. text
end

local function today_box(v, m)
	local items = lib.today_items(m)
	v.box(c.blue, "Today", #m.done .. "/" .. (#m.done + #items), function(n)
		v.add(progress(m, items, n))
		add_rows(v, m, rows_where(m, function(it)
			return it.done or (it.due and it.due <= m.today)
		end), n)
		if #items == 0 and #m.done == 0 then
			v.dim("Nothing planned for today. a adds a task; t plans the selected one.", n)
		end
	end)
end

--- Why a task is to be split, for the Next and review cards.
local function split_reason(it)
	if it.estimate then
		return "More than " .. lib.format_minutes(SPLIT_MINUTES) .. ": split it into steps"
	end
	return it.late .. "d past, no estimate: split it into steps"
end

local function next_box(v, m)
	local it, parent = lib.next_item(m)
	local est = it and lib.remaining(m, it)
	v.box(c.green, "Next", it and (est and lib.format_minutes(est) or "no est") or nil, function(n)
		if not it then
			v.dim("No task for today and no A task.", n)
			return
		end
		local action = { kind = "select", id = it.id }
		local name = rating_mark(parent or it) .. (it.recurring and (c.teal .. it.name .. " ↻" .. c.reset) or (c.bold .. it.name .. c.reset))
		for _, l in ipairs(sidecar.wrap(name, n, "", "  ", 2)) do
			v.add(l, action)
		end
		local due, late = lib.due_label((parent or it).due, m.today)
		local info = parent and ("step of " .. parent.name) or (due and (late and due or ("due " .. due)) or "no date")
		if parent and due then
			info = info .. " · " .. due
		end
		if (parent or it).moves > 0 then
			info = info .. " · moved " .. (parent or it).moves .. "×"
		end
		v.add(((late and not parent) and c.orange or c.dim) .. fit(info, n) .. c.reset, action)
		if lib.too_large(m, it) then
			v.add(c.orange .. fit(split_reason(it), n) .. c.reset, action)
		end
	end)
end

local function attention_box(v, m)
	local items = attention_items(m)
	if #items == 0 then
		return
	end
	state.attention = math.min(state.attention, #items)
	local item = items[state.attention]
	v.box(c.orange, "Attention", state.attention .. " of " .. #items, function(n)
		local action = item.id and { kind = "select", id = item.id } or nil
		for _, l in ipairs(sidecar.wrap(item.text, n, "", "")) do
			v.add(l, action)
		end
		local parts = item.proposal and { "y mark done", "n keep open" } or {}
		parts[#parts + 1] = "z hide until tomorrow"
		if #items > 1 then
			parts[#parts + 1] = "] next"
		end
		if item.id and not item.proposal then
			parts[#parts + 1] = "Enter go to task"
		end
		v.hints(parts, n)
	end)
end

local function coming_box(v, m)
	local rows = rows_where(m, function(it)
		return it.due and it.due > m.today
	end)
	v.box(c.grey, "Coming up", "7 days", function(n)
		add_rows(v, m, rows, n)
		if #rows == 0 then
			v.dim("Nothing due in the next 7 days.", n)
		end
	end)
end

local function all_boxes(v, m)
	local a_load = lib.load(m, lib.a_items(m), A_LIMIT)
	for _, rating in ipairs({ "A", "B", "C", false }) do
		local rows = rows_where(m, function(it)
			return (it.rating or false) == rating
		end)
		if #rows > 0 or rating then
			local right = tostring(#rows)
			if rating == "A" and a_load > CAPACITY then
				right = right .. " · over a day"
			end
			v.box(rating == "A" and c.orange or c.grey, rating or "Unrated", right, function(n)
				add_rows(v, m, rows, n)
				if #rows == 0 then
					v.dim("None.", n)
				end
			end)
		end
	end
end

local function review_view(v, m)
	local r = state.review
	if r.stage == "late" then
		local it = review_item(m)
		if not it then
			advance()
			return review_view(v, m)
		end
		v.box(c.purple, "Daily review · past due", r.index .. " of " .. #r.ids, function(n)
			for _, l in ipairs(sidecar.wrap(rating_mark(it) .. c.bold .. it.name .. c.reset, n, "", "  ")) do
				v.add(l)
			end
			local due = it.due and lib.day_text(it.due, true) or "no date"
			v.add(fit("Due " .. due .. " · " .. it.late .. "d past" .. (it.moves > 0 and (" · moved " .. it.moves .. "×") or ""), n))
			local steps = m.steps[it.id] or {}
			local est = lib.remaining(m, it)
			local estimate = est and ("estimate " .. lib.format_minutes(est)) or "no estimate"
			if STEPS then
				estimate = (#steps > 0 and (#steps .. " open steps") or "No steps") .. " · " .. estimate
			end
			v.add(c.dim .. fit(estimate, n) .. c.reset)
			if lib.too_large(m, it) then
				v.add(c.orange .. fit(split_reason(it), n) .. c.reset)
			end
			v.add("")
			if r.confirm then
				for _, l in ipairs(sidecar.wrap("Drop this task? It is completed with the note \"" .. DROP_NOTE .. "\". y drops it; any other key keeps it.", n, "", "")) do
					v.add(c.orange .. l .. c.reset)
				end
				return
			end
			for _, a in ipairs(lib.actions(m, it)) do
				v.add(c.bold .. a[1] .. c.reset .. "  " .. a[2])
			end
			v.add(c.dim .. "?  more choices" .. c.reset)
		end)
	elseif r.stage == "limit" then
		local a_load = lib.load(m, lib.a_items(m), A_LIMIT)
		v.box(c.purple, "Daily review · A work", lib.format_minutes(a_load) .. " of " .. lib.format_minutes(CAPACITY), function(n)
			v.dim("A work is more than one day. Rate some tasks B or C.", n)
			add_rows(v, m, rows_of(m), n)
			v.hints({ "B rate B", "C rate C", "Enter continue" }, n)
		end)
	else
		local items = lib.today_items(m)
		local load = lib.load(m, items, TODAY_LIMIT)
		v.box(c.purple, "Daily review · today", lib.format_minutes(load) .. " of " .. lib.format_minutes(CAPACITY), function(n)
			if load > CAPACITY then
				for _, l in ipairs(sidecar.wrap("More than a day of work. Move some to a later day (d).", n, "", "")) do
					v.add(c.orange .. l .. c.reset)
				end
			end
			local _, unknown = lib.time_left(m, items)
			if unknown > 0 then
				v.dim(unknown .. " without an estimate: e sets one.", n)
			end
			add_rows(v, m, rows_of(m), n)
			if #items == 0 then
				v.dim("Nothing planned for today.", n)
			end
			v.hints({ "Enter finish" }, n)
		end)
	end
end

--- The pinned header: the views, each clickable, and the date and streak.
local function header(cols)
	local parts, hits, column = {}, {}, 1
	local names = { now = "Now", today = "Today", all = "All", review = "Review" }
	for _, view in ipairs({ "now", "today", "all", "review" }) do
		if view ~= "review" or state.view == "review" then
			local label = " " .. (view == state.view and names[view]:upper() or names[view]) .. " "
			parts[#parts + 1] = view == state.view and (c.bold .. c.cyan .. label .. c.reset) or (c.dim .. label .. c.reset)
			if view ~= "review" then
				hits[#hits + 1] = { from = column, to = column + width(label) - 1, action = { kind = "view", view = view } }
			end
			column = column + width(label)
		end
	end
	local line = table.concat(parts)
	local day = today()
	local right = lib.day_text(day) .. " · streak " .. lib.streak(saved().review, day)
	if width(line) + width(right) + 1 <= cols then
		line = line .. string.rep(" ", cols - width(line) - width(right)) .. c.dim .. right .. c.reset
	end
	return line, hits
end

--- The footer: the actions that suit the selected task, and the key that
--- lists the keys.
local function hints(m)
	if state.input or state.help then
		return {}
	end
	local r = state.review
	if r and r.stage ~= "today" then
		return { "Esc leave review", "? keys" }
	end
	local parts = {}
	local it = m.by[state.selected or ""]
	if it and not it.pending then
		parts[1] = c.reset .. fit(it.name, 24) .. ":" .. c.dim
		for _, a in ipairs(lib.actions(m, it)) do
			parts[#parts + 1] = c.reset .. c.bold .. a[1] .. c.reset .. c.dim .. " " .. a[2]
		end
	end
	if r then
		parts[#parts + 1] = "Esc leave review"
	end
	parts[#parts + 1] = "? keys"
	return parts
end

--- The keys that work on the screen shown, in groups, each { title, keys },
--- a key being { key, what it does }.
local function key_groups(m)
	local r, groups = state.review, {}
	local it = target(m)
	local task = it and not it.pending
	local function group(title, keys)
		if #keys > 0 then
			groups[#groups + 1] = { title = title, keys = keys }
		end
	end
	local task_list = task and {
		{ "x", "mark the task done" }, { "t", "plan it for today" }, { "d", "give it a new date" },
		{ "e", "estimate how long it takes" }, { "E", "edit its title, rating, estimate or date" }, { "A B C", "rate it A, B or C" },
	} or {}
	if task and STEPS then
		task_list[#task_list + 1] = { "s", "split it into steps" }
	end
	if task and LISTS then
		task_list[#task_list + 1] = { "m", "move it to another list" }
	end
	if r and r.stage == "late" then
		if task then
			task_list[#task_list + 1] = { "-", "drop it: complete it with a note" }
		end
		group("This task", task_list)
		group("Review", { { "]", "skip to the next task" }, { "Esc", "leave the review" } })
	else
		task_list[#task_list + 1] = { "a", "add a new task" }
		if #rows_of(m) > 1 then
			task_list[#task_list + 1] = { "j k", "select another task" }
		end
		group("Task", task_list)
		if r then
			group("Review", { { "Enter", r.stage == "limit" and "go on to today's list" or "finish the review" }, { "Esc", "leave the review" } })
		end
	end
	local item, count = attention_item(m)
	if not r and state.view == "now" and item then
		local keys = item.proposal and { { "y", "mark the reported task done" }, { "n", "keep the reported task open" } } or {}
		keys[#keys + 1] = { "z", "hide this warning until tomorrow" }
		if count > 1 then
			keys[#keys + 1] = { "]", "show the next warning" }
		end
		if item.id then
			keys[#keys + 1] = { "Enter", "go to the task it is about" }
		end
		group("Warnings", keys)
	end
	local views_list = r and {} or { { "V", "switch between Now, Today and All" }, { "v", "start the daily review" } }
	if LISTS then
		views_list[#views_list + 1] = { "l", "choose the lists shown and the list for new tasks" }
	end
	views_list[#views_list + 1] = { "r", "fetch the tasks now" }
	views_list[#views_list + 1] = { "?", "close this list" }
	group("Views", views_list)
	return groups
end

--- The list picker: every list, the selected one marked. Choosing shows
--- which lists are shown (✓) and the default for new tasks (★); moving
--- marks the task's own list.
local function picker_box(v, m)
	local p = state.picker
	local it = p.id and m.by[p.id]
	local hidden = type(saved().hidden_lists) == "table" and saved().hidden_lists or {}
	local default = default_list()
	local current
	if p.id then
		current = select(2, find_task(p.id))
	end
	local title = p.kind == "move" and ("Move to list" .. (it and (" · " .. it.name) or "")) or "Lists"
	v.box(c.cyan, title, nil, function(n)
		for i, list in ipairs(state.lists or {}) do
			local mark = i == p.index and (c.cyan .. "› " .. c.reset) or "  "
			local note = ""
			if p.kind == "lists" then
				mark = mark .. (hidden[list.id] and (c.grey .. "○ ") or (c.green .. "✓ ")) .. c.reset
				note = list == default and (c.yellow .. " ★" .. c.reset) or ""
			elseif list == current then
				note = c.dim .. "  now here" .. c.reset
			end
			v.add(mark .. fit(list.title or "", n - width(mark) - width(note)) .. note, { kind = "pick", index = i })
			if i == p.index then
				v.selected = #v.lines
			end
		end
		v.add("")
		v.hints(p.kind == "lists" and { "Space show or hide", "d default for new tasks ★", "Esc done" }
			or { "Enter move here", "Esc cancel" }, n)
	end)
end

--- The keys that work on the screen shown.
local function help_box(v, m)
	v.box(c.grey, "Keys", "? closes", function(n)
		for i, g in ipairs(key_groups(m)) do
			if i > 1 then
				v.add("")
			end
			v.add(c.bold .. g.title .. c.reset)
			for _, k in ipairs(g.keys) do
				local key = "  " .. c.bold .. k[1] .. c.reset .. string.rep(" ", math.max(1, 7 - width(k[1])))
				for j, l in ipairs(sidecar.wrap(k[2], n - 9, "", "")) do
					v.add((j == 1 and key or string.rep(" ", 9)) .. l)
				end
			end
		end
	end)
end

function tab.view(cols)
	local pinned, hits = {}, {}
	local notice = state.key_notice or state.write_notice or state.fetch_notice or (sidecar.panel and sidecar.panel.notice)
	if state.setup_needed then
		pinned[1] = c.orange .. providers.names[provider()] .. " is not set up" .. c.reset
		local lines = {}
		local text = {
			'Ask Claude Code: "set up the sidecar Tasks tab". It checks what is done and walks you through the rest, one step at a time.',
			"Or follow the Google Tasks steps in rex-sidecar/README.md.",
			"",
			"L signs in once the client is stored · r checks again · the Reminders tab needs no setup",
		}
		if notice then
			text[#text + 1] = ""
			text[#text + 1] = notice
		end
		for i, paragraph in ipairs(text) do
			local colour = (notice and i == #text) and c.yellow or c.dim
			for _, l in ipairs(paragraph == "" and { "" } or sidecar.wrap(paragraph, cols, "", "")) do
				lines[#lines + 1] = colour .. l .. c.reset
			end
		end
		return { lines = lines, pinned = pinned }
	end
	if state.signed_out then
		local access = provider() == "apple" and "Access to Reminders needed · press L to allow it"
			or "Sign-in needed · press L to sign in"
		pinned[1] = c.orange .. access .. c.reset
		local lines = {}
		if notice then
			for _, l in ipairs(sidecar.wrap(notice, cols, "", "")) do
				lines[#lines + 1] = c.yellow .. l .. c.reset
			end
		end
		if provider() == "google" and state.sign_in_detail == "sign-in expired" then
			for _, l in ipairs(sidecar.wrap("Google ended the last sign-in. While the app is in Testing, this happens every 7 days.", cols, "", "")) do
				lines[#lines + 1] = c.dim .. l .. c.reset
			end
		end
		return { lines = lines, pinned = pinned }
	end
	if not state.lists then
		return { lines = { c.dim .. "Loading tasks…" .. c.reset }, pinned = notice and { c.yellow .. notice .. c.reset } or {} }
	end
	local line, ranges = header(cols)
	pinned[1], hits[1] = line, ranges
	if notice then
		pinned[2] = c.yellow .. fit(notice, cols) .. c.reset
	end
	local m = model()
	local v = new_view()
	v.cols = cols
	-- A blank line keeps the first box clear of the view switcher.
	pinned[#pinned + 1] = ""
	selected_index(rows_of(m), m)
	if state.input then
		input_box(v, m)
	elseif state.help then
		help_box(v, m)
	end
	if state.picker then
		picker_box(v, m)
	elseif state.view == "review" and state.review then
		review_view(v, m)
	elseif state.view == "today" then
		today_box(v, m)
		coming_box(v, m)
	elseif state.view == "all" then
		all_boxes(v, m)
	else
		next_box(v, m)
		today_box(v, m)
		attention_box(v, m)
	end
	local parts = hints(m)
	if #parts > 0 then
		v.add("")
		for _, l in ipairs(flow(parts, cols)) do
			v.add(c.dim .. l .. c.reset)
		end
	end
	if state.help then
		v.selected = 1
	elseif state.picker then
		local at
		for i, l in ipairs(v.lines) do
			if l:find("› ", 1, true) and v.actions[i] and v.actions[i].kind == "pick" then
				at = i
			end
		end
		v.selected = at or v.selected
	elseif state.input then
		-- The input line stays selected, so it scrolls into view.
		local at
		for i, l in ipairs(v.lines) do
			if l:find("▏", 1, true) then
				at = i
			end
		end
		v.selected = at or v.selected
	end
	return { lines = v.lines, actions = v.actions, pinned = pinned, hits = hits, selected = v.selected }
end

return tab
