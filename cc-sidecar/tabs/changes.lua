-- The Changes tab: the files Claude edited in its last turn, the uncommitted
-- work, and everything on the branch or its pull request. Loaded as a tab
-- plugin; see the README.
local sidecar = ...
local panel, settings, settings_dir = sidecar.panel, sidecar.settings, sidecar.settings_dir
local width, clip, fold_marks = sidecar.width, sidecar.clip, sidecar.fold_marks
local colours = sidecar.colours
local reset, bold, dim, teal = colours.reset, colours.bold, colours.dim, colours.teal
local red, green, yellow, cyan = colours.red, colours.green, colours.yellow, colours.cyan

local C = { name = "Changes", interval = 2 }

--- What the tab shows, for the repository at `root`.
local changes = {
	root = nil,
	--- From git status: whether it worked, the changed files, the branch, and
	--- whether the branch has a commit yet.
	git = false,
	files = {},
	branch = nil,
	head = true,
	scope = "Uncommitted",
	--- The third scope, "PR" or "Branch", or nil on the default branch.
	third = nil,
	tree = settings.tree(settings_dir),
	--- Folder path -> true when folded in this repository's tree.
	folded_dirs = {},
	--- Scope -> the key of the selected row.
	selected = {},
	--- The shown scope's rows, or nil before the first load.
	data = nil,
	--- The rows of the last view, by line.
	rows = {},
}

local function add(out, lines)
	for _, l in ipairs(lines) do
		out[#out + 1] = l
	end
end

--- The scopes of the Changes tab; only Last Turn works without git. The third
--- is "PR", "Branch", or nil on the default branch.
function C.scopes(git, third)
	if not git then
		return { "Last Turn" }
	end
	return { "Last Turn", "Uncommitted", third }
end

--- The scope shown when the scopes change: Branch and PR stand in for each other.
function C.pick_scope(scopes, scope)
	for _, s in ipairs(scopes) do
		if s == scope then
			return scope
		end
	end
	if (scope == "Branch" or scope == "PR") and scopes[3] then
		return scopes[3]
	end
	return scopes[1]
end

--- An open PR from `gh pr view --json number,baseRefName,state`, or nil. The base
--- becomes a git argument, so one that reads as an option is refused.
function C.pr_info(out)
	local ok, pr = pcall(rex.json.decode, out or "")
	if ok and type(pr) == "table" and pr.state == "OPEN" and type(pr.number) == "number"
		and type(pr.baseRefName) == "string" and pr.baseRefName:match("^[^-%s]%S*$") then
		return { number = math.floor(pr.number), base = pr.baseRefName }
	end
end

--- `git diff --numstat -z`, as added and removed line totals. A rename's two
--- paths are fields of their own, without the tabs a count has.
function C.numstat(out)
	local added, removed = 0, 0
	for field in out:gmatch("[^%z]+") do
		local a, r = field:match("^(%S+)\t(%S+)\t")
		added = added + (tonumber(a) or 0)
		removed = removed + (tonumber(r) or 0)
	end
	return added, removed
end

--- A scope's rows from `git status`: grouped as Staged and Unstaged, and merged
--- into one list for the tree, where a file is listed once.
function C.uncommitted(files)
	local staged, unstaged, merged = {}, {}, {}
	for _, f in ipairs(files) do
		if f.x == "?" then
			local row = { path = f.path, mark = "A", diff = "untracked" }
			unstaged[#unstaged + 1] = row
			merged[#merged + 1] = row
		else
			if f.x ~= " " then
				staged[#staged + 1] = { path = f.path, mark = f.x, diff = "staged" }
			end
			if f.y ~= " " then
				unstaged[#unstaged + 1] = { path = f.path, mark = f.y, diff = "unstaged" }
			end
			merged[#merged + 1] = { path = f.path, mark = f.y ~= " " and f.y or f.x, diff = "head" }
		end
	end
	local groups = {}
	if #staged > 0 then
		groups[#groups + 1] = { title = "Staged", rows = staged }
	end
	if #unstaged > 0 then
		groups[#groups + 1] = { title = "Unstaged", rows = unstaged }
	end
	return { groups = groups, merged = merged, note = "No uncommitted changes." }
end

--- The Branch scope from `git diff --name-status -z`. Untracked files aren't in
--- that diff, so they're added from the status.
function C.branch_rows(out, files)
	local fields = {}
	for field in out:gmatch("[^%z]+") do
		fields[#fields + 1] = field
	end
	local rows = {}
	local i = 1
	while i < #fields do
		local mark = fields[i]:sub(1, 1)
		-- A rename or copy names the path it came from, then the new one.
		if mark == "R" or mark == "C" then
			i = i + 1
		end
		rows[#rows + 1] = { path = fields[i + 1], mark = mark, diff = "base" }
		i = i + 2
	end
	for _, f in ipairs(files) do
		if f.x == "?" then
			rows[#rows + 1] = { path = f.path, mark = "A", diff = "untracked" }
		end
	end
	table.sort(rows, function(a, b)
		return a.path < b.path
	end)
	return rows
end

--- The `git` arguments that show a row's diff.
function C.diff_args(row, base, head)
	local path = row.path
	if row.diff == "staged" or (row.diff == "head" and not head) then
		return { "diff", "--cached", "--", path }
	elseif row.diff == "unstaged" then
		return { "diff", "--", path }
	elseif row.diff == "head" then
		return { "diff", "HEAD", "--", path }
	elseif row.diff == "base" then
		return { "diff", base, "--", path }
	end
	return { "diff", "--no-index", "--", "/dev/null", path }
end

local scope_short = { ["Last Turn"] = "Turn", Uncommitted = "Local" }

--- The scope row, with short names when the full ones don't fit, and the columns
--- each scope takes.
function C.scope_bar(scopes, active, cols)
	local function build(short)
		local parts, ranges, column = {}, {}, 1
		for _, scope in ipairs(scopes) do
			local label = " " .. (short and scope_short[scope] or scope) .. " "
			parts[#parts + 1] = scope == active and ("\27[7m" .. label .. reset) or (dim .. label .. reset)
			ranges[#ranges + 1] = { from = column, to = column + width(label) - 1, action = { kind = "scope", scope = scope } }
			column = column + width(label) + 1
		end
		return table.concat(parts, " "), ranges, column - 2
	end
	local bar, ranges, used = build(false)
	if used > cols then
		bar, ranges = build(true)
	end
	return bar, ranges
end

local mark_colours = { A = green, D = red, R = cyan, C = cyan, U = red }

local function coloured_mark(mark)
	return (mark_colours[mark] or yellow) .. bold .. mark .. reset
end

local function list_rows(out, built, group, selected, key_prefix)
	for _, row in ipairs(group.rows) do
		local key = key_prefix .. "\0" .. row.path
		local name = row.path:match("[^/]+$") or row.path
		local folder = row.path:match("^(.*)/[^/]*$")
		local chosen = key == selected
		out[#out + 1] = (chosen and (cyan .. "› " .. reset) or "  ")
			.. coloured_mark(row.mark) .. " " .. name
			.. (folder and (dim .. "  " .. folder .. reset) or "")
		built.actions[#out] = { kind = "open", key = key, row = row }
		built.rows[#built.rows + 1] = { key = key, row = row, line = #out }
	end
end

--- Rows as a folder tree. A folder is a row of its own that folds, and hides
--- what's under it.
local function tree_rows(out, built, rows, selected, cols, folded)
	local sorted = {}
	for _, row in ipairs(rows) do
		sorted[#sorted + 1] = row
	end
	local function folders_of(row)
		local parts, paths, path = {}, {}, nil
		for part in row.path:gmatch("[^/]+") do
			parts[#parts + 1] = part
			path = path and (path .. "/" .. part) or part
			paths[#paths + 1] = path
		end
		return parts, paths
	end
	-- Folders before files at each level, each by name.
	table.sort(sorted, function(a, b)
		local left, right = folders_of(a), folders_of(b)
		for i = 1, math.min(#left, #right) do
			if left[i] ~= right[i] then
				local left_dir, right_dir = i < #left, i < #right
				if left_dir ~= right_dir then
					return left_dir
				end
				return left[i] < right[i]
			end
		end
		return #left < #right
	end)
	local counts = {}
	for _, row in ipairs(sorted) do
		local _, paths = folders_of(row)
		for depth = 1, #paths - 1 do
			counts[paths[depth]] = (counts[paths[depth]] or 0) + 1
		end
	end
	local function mark_for(key)
		return key == selected and (cyan .. "› " .. reset) or "  "
	end
	local open = {}
	for _, row in ipairs(sorted) do
		local parts, paths = folders_of(row)
		local hidden = false
		for depth = 1, #parts - 1 do
			local path = paths[depth]
			if open[depth] ~= parts[depth] then
				open[depth] = parts[depth]
				for deeper = depth + 1, #open do
					open[deeper] = nil
				end
				if not hidden then
					local closed = folded[path] == true
					local key = "\0dir\0" .. path
					out[#out + 1] = mark_for(key) .. string.rep("  ", depth - 1) .. dim
						.. fold_marks[closed] .. parts[depth] .. (closed and (" (" .. counts[path] .. ")") or "") .. reset
					built.actions[#out] = { kind = "dir", key = key, path = path }
					built.rows[#built.rows + 1] = { key = key, dir = path, line = #out }
				end
			end
			hidden = hidden or folded[path] == true
		end
		for deeper = #parts, #open do
			open[deeper] = nil
		end
		if not hidden then
			local key = "\0" .. row.path
			local indent = mark_for(key) .. string.rep("  ", #parts - 1)
			local room = math.max(1, cols - width(indent) - 2)
			local name = clip(parts[#parts] or row.path, room)
			out[#out + 1] = indent .. name .. string.rep(" ", room - width(name) + 1) .. coloured_mark(row.mark)
			built.actions[#out] = { kind = "open", key = key, row = row }
			built.rows[#built.rows + 1] = { key = key, row = row, line = #out }
		end
	end
end

--- The Changes tab. `pinned` stays in place above the rows, and `hits` holds
--- the columns of its clickable parts, by pinned line. `actions` is by row line.
function C.changes_view(v, cols)
	local data = v.data
	local built = { lines = {}, pinned = {}, hits = {}, actions = {}, rows = {} }

	local stats = ""
	if (data.added or 0) > 0 or (data.removed or 0) > 0 then
		stats = green .. "+" .. data.added .. reset .. " " .. red .. "−" .. data.removed .. reset .. "  "
	end
	local tree_mark = "≣"
	local mark = v.tree and (teal .. tree_mark .. reset) or (dim .. tree_mark .. reset)
	local title = bold .. teal .. (v.title or "") .. reset
	if cols >= sidecar.box_min then
		-- The header is a box of its own, pinned: branch, totals and tree mark on
		-- the top line, the scopes inside.
		local head, ranges = {}, {}
		sidecar.box(head, nil, cols, teal, title, stats .. mark, function(n)
			local bar
			bar, ranges = C.scope_bar(v.scopes, v.scope, n)
			head[#head + 1] = bar
		end)
		for _, r in ipairs(ranges) do
			r.from, r.to = r.from + 2, r.to + 2
		end
		built.pinned = { head[1], head[2], head[3] }
		built.hits = { { { from = cols - 3, to = cols - 2, action = { kind = "tree" } } }, ranges }
	else
		local right = width(stats) + width(tree_mark)
		title = clip(title, math.max(1, cols - right - 1))
		built.pinned[1] = title .. reset .. string.rep(" ", math.max(1, cols - width(title) - right)) .. stats .. mark
		built.hits[1] = { { from = cols - 1, to = cols, action = { kind = "tree" } } }
		built.pinned[2] = ""
		built.pinned[3], built.hits[3] = C.scope_bar(v.scopes, v.scope, cols)
	end
	built.pinned[#built.pinned + 1] = v.notice and (red .. v.notice .. reset) or ""

	local out = built.lines
	if data.problem then
		add(out, sidecar.wrap(data.problem, cols, dim, dim))
		return built
	end
	local groups = data.groups
	if v.tree and data.merged and #data.merged > 0 then
		groups = { { title = "Changed", rows = data.merged } }
	end
	if #groups == 0 then
		add(out, sidecar.wrap(data.note, cols, dim, dim))
	end
	for _, group in ipairs(groups) do
		local count = bold .. teal .. group.title .. reset .. dim .. " " .. #group.rows .. reset
		local vs = data.vs and (dim .. "vs " .. data.vs .. reset) or ""
		sidecar.box(out, built.actions, cols, teal, count, vs, function(n)
			if v.tree then
				tree_rows(out, built, group.rows, v.selected, n, v.folded or {})
			else
				list_rows(out, built, group, v.selected, group.title)
			end
		end)
	end
	return built
end



local function git(...)
	local r = sidecar.run({ "git", "-C", panel.root, ... })
	return r and r.ok and r.stdout or ""
end

--- `git status --porcelain -b -z`: the branch, whether it has a commit yet, and
--- the changed files.
function C.status(out)
	local result = { files = {}, head = true }
	local fields = {}
	for field in out:gmatch("[^%z]+") do
		fields[#fields + 1] = field
	end
	local i = 1
	while i <= #fields do
		local f = fields[i]
		local branch = f:match("^## (.*)")
		if branch then
			result.head = not branch:match("^No commits yet")
			result.branch = branch:match("^No commits yet on (.*)$") or branch:match("^(.-)%.%.%.") or branch
		else
			local x, y, path = f:sub(1, 1), f:sub(2, 2), f:sub(4)
			-- A rename or copy is followed by the path it came from.
			if x == "R" or x == "C" then
				i = i + 1
			end
			result.files[#result.files + 1] = { x = x, y = y, path = path }
		end
		i = i + 1
	end
	return result
end

--- The ref the Branch scope compares with: where origin/HEAD points, or else
--- main or master.
local function base_ref()
	local remote = git("symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"):gsub("%s+$", "")
	if remote ~= "" then
		return remote
	end
	for _, name in ipairs({ "main", "master" }) do
		if git("rev-parse", "--verify", "--quiet", name) ~= "" then
			return name
		end
	end
end

--- The open PR of the branch, from GitHub through `gh`. It's looked up again on
--- opening Changes, on a new branch or repository, and after 5 minutes.
local pr_cache, pr_ttl = nil, 300
local function pr_lookup()
	local branch = changes.branch
	if not branch or branch:match("^HEAD") then
		return nil
	end
	local key, now = panel.root .. "\0" .. branch, os.time()
	local hit = pr_cache
	if hit and hit.key == key and now - hit.at < pr_ttl then
		return hit.pr
	end
	local r = sidecar.run({ "/bin/sh", "-c", 'export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"; cd "$1" && exec gh pr view --json number,baseRefName,state', "sh", panel.root })
	local pr = r and r.ok and C.pr_info(r.stdout) or nil
	pr_cache = { key = key, at = now, pr = pr }
	return pr
end

--- The third scope of the Changes tab, with the PR or the ref it compares with.
local function third_scope()
	if not changes.git then
		return nil
	end
	local pr = pr_lookup()
	if pr then
		local remote = "origin/" .. pr.base
		return "PR", pr, git("rev-parse", "--verify", "--quiet", remote) ~= "" and remote or pr.base
	end
	local ref = base_ref()
	if ref and changes.branch == (ref:gsub("^origin/", "")) then
		return nil
	end
	return "Branch", nil, ref
end

--- Lines in the untracked files, for the totals. git counts them only one call
--- per file, so this reads them, and leaves out big ones and long lists.
local function untracked_lines(files, root)
	local total, read = 0, 0
	for _, file in ipairs(files) do
		if file.x == "?" and read < 50 then
			read = read + 1
			local f = io.open(root .. "/" .. file.path, "rb")
			if f then
				local size = f:seek("end")
				if size and size <= 1048576 then
					f:seek("set", 0)
					local text = f:read("*a") or ""
					local _, n = text:gsub("\n", "")
					total = total + n
				end
				f:close()
			end
		end
	end
	return total
end

--- Loads the scope on show, only that one. A load that a newer one replaced
--- while git ran keeps what it found to itself.
local scope_loads = 0
local function load_scope()
	scope_loads = scope_loads + 1
	local load = scope_loads
	local third, pr, ref = third_scope()
	local scope = C.pick_scope(C.scopes(changes.git, third), changes.scope)
	local data
	if scope == "Last Turn" then
		data = sidecar.turn_data(panel.state, panel.root)
		if not panel.state.path then
			data.problem = "No Claude session found for this pane."
		end
	elseif scope == "Uncommitted" then
		data = C.uncommitted(changes.files)
		data.added, data.removed = C.numstat(git("diff", "--numstat", "-z", changes.head and "HEAD" or "--cached"))
		data.added = data.added + untracked_lines(changes.files, panel.root)
	else
		local base = ref and git("merge-base", "HEAD", ref):gsub("%s+$", "") or ""
		if base == "" then
			data = { groups = {}, problem = pr and ("No " .. pr.base .. " branch to compare with.") or "No main or master branch to compare with." }
		else
			local rows = C.branch_rows(git("diff", "--name-status", "-z", base), changes.files)
			local vs = pr and (pr.base .. " · #" .. pr.number) or (ref:gsub("^origin/", ""))
			data = { groups = #rows > 0 and { { title = "Changed", rows = rows } } or {}, note = "No changes on this branch.", vs = vs }
			data.base = base
			data.added, data.removed = C.numstat(git("diff", "--numstat", "-z", base))
			data.added = data.added + untracked_lines(changes.files, panel.root)
		end
	end
	if load == scope_loads then
		changes.third, changes.scope, changes.data = third, scope, data
		panel.cache = nil
	end
end

--- Loads the scope in the background, with the rows emptied when it's another
--- scope than the one shown.
local function reload_scope(switched)
	if switched then
		changes.data = { groups = {}, note = "Loading…" }
	end
	sidecar.spawn("scope " .. (scope_loads + 1), load_scope)
end

--- Reads `git status`, and the shown scope while the tab is open or before
--- its first load. Another repository starts at the top with nothing selected.
function C.refresh()
	if panel.root ~= changes.root then
		changes.root, changes.selected = panel.root, {}
		panel.scroll[C.name] = 0
	end
	changes.folded_dirs = settings.folded_dirs(settings_dir, panel.root)
	-- One status call: git status runs slowly in big repositories.
	local r = sidecar.run({ "git", "-C", panel.root, "status", "--porcelain", "-b", "-z", "--untracked-files=all" })
	changes.git = r and r.ok or false
	changes.files, changes.branch, changes.head = {}, nil, true
	if changes.git then
		local status = C.status(r.stdout)
		changes.files, changes.branch, changes.head = status.files, status.branch, status.head
	end
	if panel.tab == C.name or not changes.data then
		load_scope()
	end
end

--- Opening the tab looks up the PR again and loads the scope.
function C.activate()
	pr_cache = nil
	reload_scope(false)
end

function C.badge()
	return #changes.files > 0 and #changes.files or nil
end

function C.view(cols)
	local built = C.changes_view({
		title = changes.branch or (panel.root:match("[^/]+$") or panel.root),
		scope = changes.scope,
		scopes = C.scopes(changes.git, changes.third),
		tree = changes.tree,
		folded = changes.folded_dirs,
		selected = changes.selected[changes.scope],
		data = changes.data or { groups = {}, note = "Loading…" },
		notice = panel.notice,
	}, cols)
	changes.rows = built.rows
	for _, r in ipairs(built.rows) do
		if r.key == changes.selected[changes.scope] then
			built.selected = r.line
		end
	end
	return built
end

local function set_scope(scope)
	changes.scope = scope
	panel.scroll[C.name] = 0
	panel.notice = nil
	reload_scope(true)
end

local function next_scope()
	local scopes = C.scopes(changes.git, changes.third)
	for i, scope in ipairs(scopes) do
		if scope == changes.scope then
			set_scope(scopes[i % #scopes + 1])
			return
		end
	end
end

local function toggle_tree()
	changes.tree = not changes.tree
	pcall(settings.set_tree, settings_dir, changes.tree)
end

--- Opens a row's diff in a float.
local function open_diff(row)
	local command = { sidecar.dir .. "diff-view" }
	if row.diff == "patch" then
		local file = os.tmpname()
		local f = io.open(file, "wb")
		if not f then
			return "Can't write the diff to a temporary file."
		end
		f:write(sidecar.turn_patch(panel.state, row.absolute, row.path))
		f:close()
		command[2], command[3] = "patch", file
	else
		command[2], command[3] = "git", panel.root
		for _, arg in ipairs(C.diff_args(row, changes.data.base, changes.head)) do
			command[#command + 1] = arg
		end
	end
	return sidecar.open_float(sidecar.diff_label .. (row.path:match("[^/]+$") or row.path), command, panel.root)
end

local function toggle_dir(key, path)
	local on = not changes.folded_dirs[path]
	changes.folded_dirs[path] = on or nil
	changes.selected[changes.scope] = key
	pcall(settings.set_folded_dir, settings_dir, panel.root, path, on)
end

local function open_row(key, row)
	changes.selected[changes.scope] = key
	panel.notice = open_diff(row)
end

--- Moves the selection through the rows, folders too in the tree.
local function move(step)
	local rows = changes.rows
	local at = 0
	for i, r in ipairs(rows) do
		if r.key == changes.selected[changes.scope] then
			at = i
		end
	end
	changes.selected[changes.scope] = rows[math.max(1, math.min(#rows, at + step))].key
end

--- Opens the selected file's diff, or the first file's, or folds the selected
--- folder.
local function open_selected()
	for _, r in ipairs(changes.rows) do
		if r.key == changes.selected[changes.scope] then
			if r.dir then
				toggle_dir(r.key, r.dir)
			else
				open_row(r.key, r.row)
			end
			return
		end
	end
	for _, r in ipairs(changes.rows) do
		if r.row then
			open_row(r.key, r.row)
			return
		end
	end
end

--- Without rows, `j` and `k` are left to scroll the pane.
function C.key(k)
	if k == "s" then
		next_scope()
	elseif k == "t" then
		toggle_tree()
	elseif (k == "j" or k == "down" or k == "k" or k == "up") and #changes.rows > 0 then
		move((k == "j" or k == "down") and 1 or -1)
	elseif k == "\r" or k == "\n" then
		open_selected()
	else
		return false
	end
	return true
end

function C.act(action)
	if action.kind == "scope" then
		set_scope(action.scope)
	elseif action.kind == "tree" then
		toggle_tree()
	elseif action.kind == "open" then
		open_row(action.key, action.row)
	elseif action.kind == "dir" then
		toggle_dir(action.key, action.path)
	end
end

return C
